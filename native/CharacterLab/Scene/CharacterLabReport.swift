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
        CharacterLabTake.all.map {
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
            return String(format: "%@ float %5.2f  sink %5.2f  height %5.1f  hip range %4.1f  %5.1f m at %5.0f u/s",
                   id,
                   report.summary.worstFootFloat,
                   report.summary.deepestFootSink,
                   report.summary.maxHeight,
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
        let scale = characterScale(subject.character)
        let soleDrop = Double(CharacterRig.shoeSoleBelowAnkle * CharacterRig.shoeScale) * scale

        let left = height(pose.leftShoeBox) - soleDrop
        let right = height(pose.rightShoeBox) - soleDrop

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
        return Summary(
            worstFootFloat: soles.max() ?? 0,
            deepestFootSink: soles.min() ?? 0,
            maxHeight: samples.map(\.z).max() ?? 0,
            travelledMetres: travelled / CharacterLabScene.unitsPerMetre,
            averageSpeed: seconds > 0 ? travelled / seconds : 0,
            hipRange: (hips.max() ?? 0) - (hips.min() ?? 0))
    }

    /// The same scale `CharacterRig.pose` applies: the map's character scale — 1 in the lab —
    /// times the larger of the character's own width and height against the default 40.
    private static func characterScale(_ character: GameCharacter) -> Double {
        max((character.width ?? 40) / 40, (character.height ?? 40) / 40)
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
