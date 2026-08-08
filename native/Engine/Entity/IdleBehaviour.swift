import Foundation
import simd

/// **What a character does with itself while it is standing still.**
///
/// A rig that is not walking has, until now, done two things: breathe, and sway its arms by
/// 0.025 rad. Both are periodic, both are tiny, and both run at the same rate on every character
/// in the scene — so a playground full of pupils reads as a shelf of ornaments. The thing that
/// gives a standing person away as alive is not smoothness, it is **irregularity**: they take
/// their weight onto one leg and leave it there for eight seconds, look at something, wipe their
/// nose, shuffle a foot, and go back to standing.
///
/// So this is a scheduler, not an animation. Time is cut into beats; each beat either gets a
/// gesture or does not; and underneath the gestures a slow weight shift wanders from one leg to
/// the other on its own period. Everything comes out of `DeterministicRandom` seeded from the
/// character's id, so:
///
/// - **it is different per character** — two pupils standing together are not in unison;
/// - **it is stable** — the same character does the same thing at the same wall-clock second, so
///   nothing jitters when a frame is dropped and there is no per-character state to keep;
/// - **it is the same on every client**, because `pose` is handed `Date().timeIntervalSince1970`
///   and the seed is the character id. Two players watching the same NPC see the same fidget.
///
/// ### What it does *not* do
///
/// It never writes a limb target. Everything here is a **joint angle** — the shape the arms and
/// legs were re-authored into (see `CharacterRig.armTarget` / `legTarget`) — or a body-pivot
/// offset. A gesture that pushed a hand through space would be silently clamped by the IK, which
/// is the trap that has cost this rig two sessions.
enum IdleBehaviour {

    // MARK: - What comes out

    /// One arm's three angles, as an **absolute** pose rather than an offset.
    ///
    /// Reaching for your own face is not "the hanging arm, plus a bit". It is somewhere else
    /// entirely, and the only sane way to write it down is where the arm ends up. `weight`
    /// crossfades between the resting arm and this, so a gesture eases in and out of whatever
    /// else the pose is doing.
    struct ArmReach {
        var swing: Float
        var sideways: Float
        var flex: Float
        var weight: Float
    }

    /// One leg's three angles, as offsets from wherever the leg already is. Legs never need the
    /// absolute treatment — nothing a standing person does with a foot is far from standing.
    struct LegOffset {
        var swing: Float = 0
        var sideways: Float = 0
        var flex: Float = 0
    }

    /// Everything one frame of idling asks for. Named for the **character's** own sides, the
    /// same way `CharacterRig.pose` names its angle variables.
    struct Offsets {
        var rightArm: ArmReach?
        var leftArm: ArmReach?
        var rightLeg = LegOffset()
        var leftLeg = LegOffset()

        /// Head, in the chest's frame: turn about up (+ is towards the character's left), pitch
        /// (+ is chin down), tilt (+ drops the head towards the character's right ear).
        var headTurn: Float = 0
        var headPitch: Float = 0
        var headTilt: Float = 0

        /// Shoulders against hips, + towards the character's left.
        var chestTwist: Float = 0

        /// Body pivot translation: x forward, y towards the character's left, z up.
        var hipShift = SIMD3<Float>(repeating: 0)
        /// Body pivot rotation, added to the existing lean: x rolls, y pitches.
        var lean = SIMD2<Float>(repeating: 0)
    }

    // MARK: - The knobs

    /// How long one scheduling beat is, and how often a beat gets a gesture at all. Together
    /// these set the pace: 3.6 s beats at a 0.42 chance is a fidget roughly every 8.5 seconds,
    /// which is about right for a child waiting for something to happen. Turn `gestureChance`
    /// down to make everyone calmer; there is no other pacing number.
    static let beatLength: Double = 3.6
    static let gestureChance = 0.42

    /// How far the hips travel sideways when the weight goes onto one leg, **as an angle at the
    /// hip** rather than a distance, so it stays right if the legs change length. 0.075 rad on a
    /// 25-unit leg is a shade under two units — small, and the single most valuable thing in this
    /// file, because a person standing with their weight evenly on both feet is a person standing
    /// to attention.
    static let weightShiftAngle: Float = 0.075

    // MARK: - The whole thing

    /// A stable 64-bit seed for a character. `consistentRandom`'s 32-bit hash is reused rather
    /// than invented afresh so a character's idle habits travel with its head and hair colour.
    static func seed(for id: Int) -> UInt64 {
        UInt64(bitPattern: Int64(id)) &* 0x9E37_79B9_7F4A_7C15 ^ 0x5DEE_CE66_D1B0_1F3D
    }

    static func offsets(seed: UInt64, time: Double, legSpan: Float) -> Offsets {
        var out = Offsets()
        applyWeightShift(&out, seed: seed, time: time, legSpan: legSpan)
        applyGesture(&out, seed: seed, time: time, legSpan: legSpan)
        return out
    }

    // MARK: - Standing on one leg

    /// **The slow one.** Every 7–13 seconds the character decides, per character, whether to put
    /// its weight on its left leg or its right, and then leaves it there. That is not a cycle —
    /// two beats in a row can pick the same side and the character simply does not move, which is
    /// what stops it reading as a metronome.
    ///
    /// The hips translate towards the loaded foot, **and both legs abduct by the angle that keeps
    /// their feet where they were**. Without that second half the feet slide along with the hips
    /// and the whole thing reads as the character being dragged sideways rather than shifting its
    /// weight. The loaded knee straightens and the free one softens, which is the rest of it;
    /// `CharacterRig.groundContactSink` then lifts the body by however far the straightened leg
    /// pushes it, on its own, because that is what a straightening leg does.
    private static func applyWeightShift(_ out: inout Offsets,
                                         seed: UInt64,
                                         time: Double,
                                         legSpan: Float) {
        var rng = DeterministicRandom(seed: seed)
        let period = rng.range(7, 13)
        let offset = rng.unit() * period

        let t = (time + offset) / period
        let index = t.rounded(.down)
        let progress = Float(t - index)

        // Ease from the previous beat's choice into this one over the first fifth of it. A
        // weight shift takes about a second and a half; the rest of the beat is holding it.
        let blend = smoothstep(min(1, progress / 0.2))
        let shift = mix(side(seed: seed, beat: index - 1), side(seed: seed, beat: index), blend)

        loadWeight(&out, towards: shift, amount: 1, legSpan: legSpan)
    }

    /// Which leg this character stands on for beat `index`. ±1, + towards the character's left.
    private static func side(seed: UInt64, beat: Double) -> Float {
        var rng = DeterministicRandom(seed: seed &+ 0x9E37 &* UInt64(bitPattern: Int64(beat)))
        return rng.chance(0.5) ? 1 : -1
    }

    /// Puts the weight onto one leg. `towards` is +1 for the character's left, −1 for their
    /// right, and anything in between for a body caught mid-shift.
    ///
    /// Shared by the slow shift above and by `adjustFoot`, which has to get the weight off a foot
    /// before it can pick it up.
    private static func loadWeight(_ out: inout Offsets,
                                   towards: Float,
                                   amount: Float,
                                   legSpan: Float) {
        let angle = weightShiftAngle * amount
        out.hipShift.y += towards * angle * legSpan

        // The hips moved, so both hips moved, so both legs have to lean back the other way by
        // the same angle or the feet come with them.
        out.leftLeg.sideways -= towards * angle
        out.rightLeg.sideways -= towards * angle

        // The loaded leg takes the weight straight; the free one bends and its hip drops.
        let loaded = max(0, towards) * amount, free = max(0, -towards) * amount
        out.leftLeg.flex -= loaded * 0.05
        out.leftLeg.flex += free * 0.12
        out.rightLeg.flex -= free * 0.05
        out.rightLeg.flex += loaded * 0.12

        // The shoulders stay over the middle while the hips do not, so the spine has to bend
        // back. Positive pivot roll drops the top towards the character's right.
        out.lean.x += towards * 0.035 * amount
        out.chestTwist -= towards * 0.04 * amount
    }

    // MARK: - The gestures

    private enum Gesture {
        case lookAround
        case adjustFoot
        case wipeNose
        case scratchHead
        case stretchNeck
        case rockOnFeet

        /// How long it takes, before the per-instance jitter. Every one of these has to fit
        /// inside a beat — see `applyGesture`.
        var duration: Double {
            switch self {
            case .lookAround:  return 2.2
            case .adjustFoot:  return 0.85
            case .wipeNose:    return 1.5
            case .scratchHead: return 1.9
            case .stretchNeck: return 1.8
            case .rockOnFeet:  return 2.4
            }
        }
    }

    /// How often each one comes up. Looking about is most of what a bored person does; the
    /// hand-to-face ones are the most noticeable and so the rarest.
    private static let gestureWeights: [(Gesture, Double)] = [
        (.lookAround, 0.30),
        (.adjustFoot, 0.20),
        (.rockOnFeet, 0.14),
        (.stretchNeck, 0.14),
        (.wipeNose, 0.12),
        (.scratchHead, 0.10),
    ]

    /// Picks this beat's gesture, if it has one, and poses it.
    ///
    /// A gesture is drawn from, started inside and finished inside **one** beat. That is the
    /// whole reason the schedule is beat-shaped: nothing has to be remembered between frames, and
    /// a gesture can never be interrupted half way through by the next beat's draw — which would
    /// snap a hand back from a face.
    private static func applyGesture(_ out: inout Offsets,
                                     seed: UInt64,
                                     time: Double,
                                     legSpan: Float) {
        let index = (time / beatLength).rounded(.down)
        var rng = DeterministicRandom(seed: seed &+ 0xB5AD_4ECE &* UInt64(bitPattern: Int64(index)))

        guard rng.chance(gestureChance) else { return }

        let gesture = pick(&rng)
        let duration = gesture.duration * rng.range(0.85, 1.15)
        let slack = max(0, beatLength - duration)
        let start = index * beatLength + rng.range(0, slack)
        // +1 is the character's left, matching local +Y everywhere else in the rig.
        let towards: Float = rng.chance(0.5) ? 1 : -1

        let progress = (time - start) / duration
        guard progress >= 0, progress <= 1 else { return }
        let u = Float(progress)

        switch gesture {
        case .lookAround:
            // Head goes first and furthest, the chest follows a little, and the eyes — which
            // this rig does not have — would have gone first of all.
            let w = envelope(u, rise: 0.3, fall: 0.35)
            out.headTurn += towards * 0.55 * w
            out.headPitch -= 0.05 * w
            out.chestTwist += towards * 0.09 * w

        case .stretchNeck:
            // An ear towards a shoulder, and a small turn with it. This is the one that reads
            // best from the game's near-overhead camera, where a yaw is nearly invisible.
            let w = envelope(u, rise: 0.35, fall: 0.4)
            out.headTilt -= towards * 0.24 * w
            out.headTurn += towards * 0.12 * w
            out.headPitch += 0.05 * w

        case .adjustFoot:
            // Take the weight off it, fold the knee enough to break contact, put it down a
            // little further out. `groundContactSink` reads the *lower* foot, so lifting one
            // leaves the body where it is, which is exactly right.
            let w = envelope(u, rise: 0.35, fall: 0.45)
            loadWeight(&out, towards: -towards, amount: w * 0.8, legSpan: legSpan)
            let lift = w * 0.42
            if towards > 0 {
                out.leftLeg.flex += lift
                out.leftLeg.swing += w * 0.10
                out.leftLeg.sideways += w * 0.09
            } else {
                out.rightLeg.flex += lift
                out.rightLeg.swing += w * 0.10
                out.rightLeg.sideways -= w * 0.09
            }
            out.headPitch += w * 0.06

        case .wipeNose:
            // The hand goes to the face and rubs twice. `sideways` is signed absolutely, not
            // per-arm (see `armTarget`), so the arm coming across the body to the midline is
            // +0.65 on the character's right and −0.65 on their left.
            let w = envelope(u, rise: 0.3, fall: 0.3)
            let rub = Float(sin(Double(u) * .pi * 6)) * 0.05 * w
            let reach = ArmReach(swing: 2.78 + rub, sideways: 0.65, flex: 1.78, weight: w)
            place(&out, arm: towards, reach: reach)
            out.headPitch += w * 0.07

        case .scratchHead:
            let w = envelope(u, rise: 0.3, fall: 0.3)
            let rub = Float(sin(Double(u) * .pi * 5)) * 0.07 * w
            let reach = ArmReach(swing: 3.22, sideways: 0.32 + rub, flex: 1.45, weight: w)
            place(&out, arm: towards, reach: reach)
            out.headTilt -= towards * 0.08 * w

        case .rockOnFeet:
            // Weight rolls forward onto the toes and back onto the heels once. No ankle joint to
            // do it with, so it is the pivot translating and the body tipping together — which
            // is what the ankles would have produced anyway.
            let w = envelope(u, rise: 0.25, fall: 0.25)
            let roll = Float(sin(Double(u) * .pi * 2)) * w
            out.hipShift.x += roll * 1.3
            out.lean.y += roll * 0.045
        }
    }

    /// Writes an absolute arm pose onto the correct side. `towards` +1 is the character's left.
    ///
    /// The mirror is in `sideways` only, because that angle is measured against the world's +Y
    /// and not against the arm's own body — the same convention `CharacterRig.pose` uses when it
    /// starts the two arms at `+neutralArmSideways` and `−neutralArmSideways`.
    private static func place(_ out: inout Offsets, arm towards: Float, reach: ArmReach) {
        if towards > 0 {
            var mirrored = reach
            mirrored.sideways = -reach.sideways
            out.leftArm = mirrored
        } else {
            out.rightArm = reach
        }
    }

    private static func pick(_ rng: inout DeterministicRandom) -> Gesture {
        let total = gestureWeights.reduce(0) { $0 + $1.1 }
        var roll = rng.unit() * total
        for (gesture, weight) in gestureWeights {
            roll -= weight
            if roll <= 0 { return gesture }
        }
        return .lookAround
    }

    // MARK: - Shaping

    /// Rise, hold, fall. A gesture that eased all the way in and straight back out again would
    /// have no moment where it *is* the thing it is doing — a nose gets wiped, not brushed past.
    private static func envelope(_ u: Float, rise: Float, fall: Float) -> Float {
        if u < rise { return smoothstep(u / rise) }
        if u > 1 - fall { return smoothstep((1 - u) / fall) }
        return 1
    }

    private static func smoothstep(_ x: Float) -> Float {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }

    private static func mix(_ a: Float, _ b: Float, _ t: Float) -> Float {
        a + (b - a) * t
    }
}
