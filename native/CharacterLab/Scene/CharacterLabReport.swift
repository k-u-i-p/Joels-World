import Foundation
import simd

/// **The lab's numbers.** The same takes the pictures come from, sampled and measured instead
/// of drawn.
///
/// A screenshot answers "does this look right", and it is the only thing that can. It cannot
/// answer "is the foot on the floor at every point of the stride, at every throttle" — that is
/// twenty numbers per frame over a hundred frames, and reading them off a picture is guesswork.
/// So the lab does both: `CharacterLabCapture` writes the filmstrip, and this writes the table
/// underneath it.
///
/// Nothing here touches Metal. It poses the rig itself, off a `CharacterLabScene` driven by the
/// same fixed sub-step, so a report can be produced with no window and no GPU at all.
enum CharacterLabReport {

    /// **Measure the models before measuring the takes.**
    ///
    /// A report poses the rig and never draws it, which is the point — no window, no GPU, runs on
    /// a build machine. But `CharacterRig` asks `WornLegs` which leg the character is wearing, and
    /// `WornLegs` is filled in by `ImportedCharacterStore` as it uploads a model to the GPU. No
    /// draw, no upload, no leg: every take measured against `WornLeg.rig` — the rig's own abstract
    /// bones and a slip-on shoe nothing has worn since part 4 — and the numbers came out *the
    /// same for all five characters*, which is exactly what a foot report cannot afford to be.
    ///
    /// So the report does the half of the load it actually needs. `GLTFLoader.load` and
    /// `HumanoidSkeleton.init` are both plain CPU: the parse, the bone matching, the foot
    /// measurement and the leg measurement all happen with no Metal anywhere near them. Only the
    /// vertex buffers and the textures need a device, and a number does not need those.
    ///
    /// Cheap enough to do unconditionally — five files, parsed once per process.
    /// - Parameter models: the catalogue, plus whatever `JW_CHARACTER_MODEL` names — a model being
    ///   tried out for the first time is not in the catalogue yet, and it is exactly the one a
    ///   report is being run about.
    static func warmUp(models: [String] = CharacterModels.all.map(\.path)
                        + [CharacterModels.defaultPath]
                        + [CharacterModels.override].compactMap { $0 }) {
        for path in Set(models) {
            guard let url = AssetLocator.url(for: path),
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let asset = try? GLTFLoader.load(data: data),
                  let mesh = asset.skinnedMeshes.first
            else {
                Log.render("Report: '\(path)' would not parse — measured as the rig's own leg")
                continue
            }
            let skeleton = HumanoidSkeleton(mesh: mesh, profile: .standard)
            guard let leg = skeleton.wornLeg else {
                Log.render("Report: '\(path)' has no measurable leg — measured as the rig's own")
                continue
            }
            WornLegs.publish(leg, for: path)
            if let arm = skeleton.wornArm { WornArms.publish(arm, for: path) }
            skeletons[path] = skeleton
            if CharacterLabArguments.wantsSkeletonReport {
                Log.render("--- \(path) ---\n" + skeleton.describe(jointNames: mesh.jointNames))
            }
        }
    }

    /// The parsed skeletons `warmUp` built, so the drawn foot can be measured as well as the
    /// intended one. See `drawn(_:model:)`.
    private static var skeletons: [String: HumanoidSkeleton] = [:]
    private static var retargeters: [String: HumanoidRetargeter] = [:]
    private static var jointScratch: [Float4x4] = []

    /// **Where this pose's shoes actually ended up**, by running the same retargeter the renderer
    /// runs and skinning two points of each sole through it.
    ///
    /// The rest of this file measures `RigPose.leftShoeBox` — the frame the rig *hands* the
    /// retargeter. That is worth measuring and it is not the same question: a report built on it
    /// says the rig asked for a flat foot on the floor, and stays silent if the retargeter then
    /// draws it pointing at the sky. Which is what it was doing.
    static func drawn(_ pose: RigPose) -> (lowest: Double, tilt: Double)? {
        guard let skeleton = skeletons[pose.model] else { return nil }
        let retargeter = retargeters[pose.model] ?? {
            let made = HumanoidRetargeter(skeleton: skeleton)
            retargeters[pose.model] = made
            return made
        }()
        retargeter.solve(pose: pose, into: &jointScratch)
        let soles = retargeter.drawnSole()
        guard !soles.isEmpty else { return nil }

        // The foot that is down decides both numbers: the lowest point of either sole, and how
        // far *that* foot's toe is above its own heel.
        let lower = soles.min { min($0.toe.z, $0.heel.z) < min($1.toe.z, $1.heel.z) ? true : false }!
        return (lowest: Double(min(lower.toe.z, lower.heel.z)),
                tilt: Double(lower.toe.z - lower.heel.z))
    }

    /// One posed instant.
    struct Sample: Codable {
        var t: Double

        var x: Double
        var y: Double
        var z: Double
        var facing: Double
        var speed: Double

        var phase: Double
        var intensity: Double
        var run: Double
        var forward: Double
        var lateral: Double
        var leanForward: Double
        var leanLateral: Double
        var turning: Double

        /// Height of each shoe's sole above the floor, in world units. Negative is the
        /// deliberate `CharacterRig.footSink`; a large positive number is a character walking
        /// on air.
        var leftSole: Double
        var rightSole: Double
        var lowestSole: Double

        /// **Toe height minus heel height**, per shoe, in world units. Zero is a sole flat on the
        /// floor; positive is a character up on its heels, negative is up on its toes. See
        /// `CharacterRig.soleTilt` for why a clearance on its own could not say.
        var leftTilt: Double
        var rightTilt: Double

        /// **The same two numbers off the mesh that gets drawn**, via `drawn(_:)`: the lowest
        /// point of the lower shoe and how far its toe is above its own heel. Everything above is
        /// what the rig asked for; these are what it got. `nil` if the model has not been parsed.
        var drawnSole: Double?
        var drawnTilt: Double?

        /// Hip, head and hands, in world units above the floor. Enough to see a bounce, a
        /// crouch or an arm swing without a picture.
        var hip: Double
        var head: Double
        var leftHand: Double
        var rightHand: Double
    }

    /// What a whole take did.
    struct Summary: Codable {
        /// The most any foot was left hanging in the air at the bottom of its arc. This is the
        /// contact promise: on a grounded take it should stay within a unit or so of zero.
        var worstFootFloat: Double
        /// The deepest a sole went under the floor. `CharacterRig.footSink` is 0.4 by design.
        var deepestFootSink: Double
        /// **The most either sole was tilted while it was on the floor**, toe against heel, in
        /// world units. A planted foot should be flat, so this is near zero on a grounded take;
        /// a foot in the air is allowed any pitch it likes and is not counted.
        var worstPlantedTilt: Double
        /// **The drawn sole**, the two numbers that matter measured off the mesh rather than off
        /// the frame the rig handed the retargeter. `worstDrawnFloat` is the lower shoe at its
        /// most airborne; `worstDrawnTilt` is how far from flat it got while it was down.
        var worstDrawnFloat: Double
        var worstDrawnTilt: Double
        /// How high the character got off the ground.
        var maxHeight: Double
        /// How far they travelled, in metres, and how fast on average.
        var travelledMetres: Double
        var averageSpeed: Double
        /// Hip height range — the walk's bounce, measured.
        var hipRange: Double
    }

    struct TakeReport: Codable {
        var id: String
        var title: String
        var watchFor: String
        var seconds: Double
        var speedScale: Double
        var summary: Summary
        var samples: [Sample]
    }

    /// Runs a take and measures the first subject in the cast.
    ///
    /// - Parameter samples: how many evenly-spaced instants to record across the take.
    static func measure(take: CharacterLabTake,
                        cast: CharacterLabCast.Kind = .solo,
                        speedScale: Double = 1,
                        samples count: Int = 48) -> TakeReport {
        let scene = CharacterLabScene(take: take.id, cast: cast)
        scene.speedScale = speedScale
        scene.isPaused = true
        scene.start()
        defer { scene.stop() }

        let runtime = RigRuntime()
        var samples: [Sample] = []
        samples.reserveCapacity(count)

        var startPosition = SIMD2<Double>.zero
        var travelled: Double = 0
        var previous: SIMD2<Double>?

        for index in 0..<max(2, count) {
            let t = take.seconds * Double(index) / Double(max(1, count - 1))
            scene.seek(to: t)
            guard let subject = scene.subjects.first else { break }

            let here = SIMD2(subject.motor.x, subject.motor.y)
            if index == 0 { startPosition = here }
            if let previous { travelled += distance(previous, here) }
            previous = here

            let pose = CharacterRig.pose(character: subject.character,
                                         gait: subject.motor.gait,
                                         mapCharacterScale: 1,
                                         time: SceneClock.now,
                                         runtime: runtime,
                                         override: subject.motor.poseOverride())

            samples.append(sample(t: t, subject: subject, pose: pose))
        }

        _ = startPosition
        return TakeReport(id: take.id,
                          title: take.title,
                          watchFor: take.watchFor,
                          seconds: take.seconds,
                          speedScale: speedScale,
                          summary: summarise(samples, travelled: travelled, seconds: take.seconds),
                          samples: samples)
    }

    /// Every take, measured. What `-labreport` writes.
    static func measureAll(cast: CharacterLabCast.Kind = .solo,
                           speedScale: Double = 1,
                           samples: Int = 48) -> [TakeReport] {
        warmUp()
        return CharacterLabTake.all.map {
            measure(take: $0, cast: cast, speedScale: speedScale, samples: samples)
        }
    }

    /// **One stride, in seconds.** Where a filmstrip of a moving take should start and how long
    /// it should run.
    ///
    /// Eight frames spread evenly over a six-second walk is eight pictures of a character in
    /// nearly the same pose, because the sampling interval and the cadence are unrelated
    /// numbers that happen to nearly agree. Eight frames over one stride is a walk cycle. The
    /// only honest way to know how long a stride takes is to run one: the cadence depends on
    /// the speed, the speed on the throttle, and the stride length shortens at a crawl.
    ///
    /// Returns nil for a take whose subject never takes a step, which is every emote and the
    /// standing take — those want the whole take.
    static func strideWindow(take: CharacterLabTake,
                             cast: CharacterLabCast.Kind = .solo,
                             speedScale: Double = 1) -> (start: Double, duration: Double)? {
        let scene = CharacterLabScene(take: take.id, cast: cast)
        scene.speedScale = speedScale
        scene.isPaused = true
        scene.start()
        defer { scene.stop() }

        // Long enough for the acceleration to be over and the gait to be steady.
        let settle = min(1.5, take.seconds * 0.3)
        let step = 1.0 / 60
        var unwrapped: Double = 0
        var previousPhase: Double?
        var atSettle: Double?

        var t = 0.0
        while t <= take.seconds {
            scene.seek(to: t)
            guard let gait = scene.subjects.first?.motor.gait else { return nil }

            // The phase wraps at 4π (`Locomotion.resolve`), so it is accumulated by difference
            // rather than read directly.
            if let previous = previousPhase {
                var delta = gait.phase - previous
                if delta < -.pi { delta += .pi * 4 }
                if delta > .pi * 3 { delta -= .pi * 4 }
                unwrapped += max(0, delta)
            }
            previousPhase = gait.phase

            if t >= settle {
                if let start = atSettle {
                    if unwrapped - start >= .pi * 2 { return (settle, t - settle) }
                } else {
                    atSettle = unwrapped
                }
            }
            t += step
        }
        return nil
    }

    static func json(_ reports: [TakeReport]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(reports)
    }

    /// A one-line-per-take digest for the console, so a run says something useful without the
    /// JSON being opened.
    static func digest(_ reports: [TakeReport]) -> String {
        reports.map { report in
            // `%-16@` does not pad an object argument, so the column is built rather than
            // formatted — otherwise every line starts in a different place and the table the
            // digest exists to be stops being one.
            let id = report.id.count >= 16 ? report.id
                : report.id.padding(toLength: 16, withPad: " ", startingAt: 0)
            return String(format: "%@ float %5.2f  sink %5.2f  tilt %5.2f  |  DRAWN float %6.2f  tilt %6.2f  |  hip range %4.1f  %5.1f m at %5.0f u/s",
                   id,
                   report.summary.worstFootFloat,
                   report.summary.deepestFootSink,
                   report.summary.worstPlantedTilt,
                   report.summary.worstDrawnFloat,
                   report.summary.worstDrawnTilt,
                   report.summary.hipRange,
                   report.summary.travelledMetres,
                   report.summary.averageSpeed)
        }.joined(separator: "\n")
    }

    // MARK: - Measuring one frame

    private static func sample(t: Double,
                               subject: CharacterLabScene.Subject,
                               pose: RigPose) -> Sample {
        let gait = subject.motor.gait

        // **The lowest corner of the shoe, not the height of the ankle minus a constant.** That
        // constant is `shoeSoleBelowAnkle`, and subtracting it answers "how high is the sole" for
        // a level foot only — which was every foot the rig produced until the shoe learned to
        // pitch. A toe-down foot's toe is lower than that answer by most of a shoe, and the whole
        // point of measuring a sole is to catch exactly that. See `CharacterRig.soleClearance`.
        //
        // **Against the model's own shoe**, which is the other half of the same point: measuring
        // a bought character's sole with the slip-on's depth was a number that could not be wrong,
        // because it never looked at the thing on the floor. See `FootShape`.
        //
        // That claim was false for a whole session, and silently. `shape(for:)` answers off
        // `WornLegs`, which is filled in by the **render** layer as models load — and a report
        // loads nothing, so every model measured as the slip-on and all five came back with
        // identical numbers to the centimetre. Nothing said so; the digest just looked stable.
        // `warmUp` below is what makes the lookup mean something. See `CharacterLabReport.warmUp`.
        let foot = WornLegs.shape(for: pose.model)
        let drawn = drawn(pose)
        let left = Double(CharacterRig.soleClearance(pose.leftShoeBox, foot: foot))
        let right = Double(CharacterRig.soleClearance(pose.rightShoeBox, foot: foot))

        return Sample(t: t,
                      x: subject.motor.x,
                      y: subject.motor.y,
                      z: subject.motor.z,
                      facing: subject.motor.facing,
                      speed: subject.motor.speed,
                      phase: gait.phase,
                      intensity: gait.intensity,
                      run: gait.run,
                      forward: gait.forward,
                      lateral: gait.lateral,
                      leanForward: gait.leanForward,
                      leanLateral: gait.leanLateral,
                      turning: gait.turning,
                      leftSole: left,
                      rightSole: right,
                      lowestSole: min(left, right),
                      leftTilt: Double(CharacterRig.soleTilt(pose.leftShoeBox, foot: foot)),
                      rightTilt: Double(CharacterRig.soleTilt(pose.rightShoeBox, foot: foot)),
                      drawnSole: drawn?.lowest,
                      drawnTilt: drawn?.tilt,
                      hip: partHeight(pose, .pelvis),
                      head: height(pose.headTransform),
                      leftHand: partHeight(pose, .leftHand),
                      rightHand: partHeight(pose, .rightHand))
    }

    private static func summarise(_ samples: [Sample],
                                  travelled: Double,
                                  seconds: Double) -> Summary {
        let soles = samples.map(\.lowestSole)
        let hips = samples.map(\.hip)
        // Only a foot that is actually *down* has an opinion about being flat, and down means
        // under the floor: `shoeFrame` sinks a planted sole by `footSink`, so anything at or below
        // half of that is taking weight and anything above it is swinging. A looser threshold
        // reads the idle weight-shift — a foot a unit up, tilted, on its way somewhere — as a
        // character standing crooked, which is how this number first lied about `stand`.
        let planted = -Double(CharacterRig.footSink) / 2
        let plantedTilts = samples.flatMap { sample -> [Double] in
            var tilts: [Double] = []
            if sample.leftSole <= planted { tilts.append(abs(sample.leftTilt)) }
            if sample.rightSole <= planted { tilts.append(abs(sample.rightTilt)) }
            return tilts
        }
        return Summary(
            worstFootFloat: soles.max() ?? 0,
            deepestFootSink: soles.min() ?? 0,
            worstPlantedTilt: plantedTilts.max() ?? 0,
            worstDrawnFloat: samples.compactMap(\.drawnSole).max() ?? 0,
            worstDrawnTilt: samples.compactMap { sample in
                guard let sole = sample.drawnSole, let tilt = sample.drawnTilt,
                      sole <= planted else { return nil }
                return abs(tilt)
            }.max() ?? 0,
            maxHeight: samples.map(\.z).max() ?? 0,
            travelledMetres: travelled / CharacterLabScene.unitsPerMetre,
            averageSpeed: seconds > 0 ? travelled / seconds : 0,
            hipRange: (hips.max() ?? 0) - (hips.min() ?? 0))
    }

    private static func partHeight(_ pose: RigPose, _ part: RigPart) -> Double {
        guard let entry = pose.parts.first(where: { $0.part == part }) else { return 0 }
        return height(entry.transform)
    }

    private static func height(_ transform: Float4x4) -> Double {
        Double(transform.columns.3.z)
    }

    private static func distance(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        hypot(b.x - a.x, b.y - a.y)
    }
}
