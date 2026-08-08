import Foundation
import simd

/// The four limb endpoints a caller can drive.
///
/// Hands and feet, not shoulders and knees: the rig is solved by two-bone IK, so an endpoint is
/// the only thing there is to aim. Where the elbow ends up is `IKSolver`'s business.
enum Limb: CaseIterable {
    case leftHand, rightHand, leftFoot, rightFoot

    var isHand: Bool { self == .leftHand || self == .rightHand }

    /// Where the limb hangs from, in the rig's local frame (+X forward, +Y the character's
    /// left, +Z up, origin at the body pivot). Reach is measured from here.
    var root: SIMD3<Float> {
        switch self {
        case .leftHand: return CharacterRig.leftShoulder
        case .rightHand: return CharacterRig.rightShoulder
        case .leftFoot: return CharacterRig.leftHip
        case .rightFoot: return CharacterRig.rightHip
        }
    }

    /// Where the rig puts it when nothing is driving it. A released limb settles back here, and
    /// a motor that has never been posed starts here.
    var neutral: SIMD3<Float> {
        switch self {
        case .leftHand: return CharacterRig.neutralLeftHand
        case .rightHand: return CharacterRig.neutralRightHand
        case .leftFoot: return CharacterRig.neutralLeftFoot
        case .rightFoot: return CharacterRig.neutralRightFoot
        }
    }
}

/// How fast a limb can be moved and how far it can get.
///
/// The reach numbers are not decoration. `IKSolver.solve` silently clamps a target it cannot
/// reach, which means a caller asking for something impossible gets *something* back and no way
/// to know it was refused — the tennis game spent a session missing every ball for exactly that
/// kind of reason. Clamping here instead makes the refusal visible: `LimbState.strain` is how
/// far outside its reach the ask was.
struct LimbProfile {
    /// Local units per second the endpoint can travel.
    var maxSpeed: Float
    /// Local units per second squared it can change that by. This is what gives a hand weight:
    /// a low number and it winds up before it moves.
    var acceleration: Float
    /// How hard it homes in. Higher arrives sooner and overshoots less; it is the arrival
    /// behaviour, in units of "speed per unit of remaining distance".
    var approachGain: Float = 14
    /// Full extension, joint to endpoint. Slightly inside the true bone sum, because a limb
    /// solved dead straight is a locked knee and looks like one.
    var maxReach: Float
    /// How close to its own root the endpoint may come before the two bones fold flat.
    var minReach: Float
    /// Seconds to hand control over from the rig's own animation, and to hand it back. Without
    /// it a hand snaps from the walk cycle to wherever a minigame wants it.
    var engageTime: Double = 0.10
    var releaseTime: Double = 0.18

    /// An arm. `armBone` is 8.5 twice over, so 16.6 is full extension with a whisker left in
    /// the elbow.
    static let arm = LimbProfile(maxSpeed: 900,
                                 acceleration: 12_000,
                                 maxReach: CharacterRig.armBone * 2 - 0.4,
                                 minReach: 3.5)

    /// A leg. Slower and heavier than an arm, and it may not fold as tightly.
    static let leg = LimbProfile(maxSpeed: 700,
                                 acceleration: 9_000,
                                 maxReach: CharacterRig.thighBone + CharacterRig.shinBone - 0.4,
                                 minReach: 6)

    /// Clamps a point into the spherical shell this limb can actually reach, about `root`.
    func reachable(_ point: SIMD3<Float>, from root: SIMD3<Float>) -> SIMD3<Float> {
        var delta = point - root
        let distance = simd_length(delta)
        if distance < 1e-5 { delta = SIMD3(0, 0, -1); return root + delta * minReach }
        if distance > maxReach { return root + delta / distance * maxReach }
        if distance < minReach { return root + delta / distance * minReach }
        return point
    }
}

/// One limb endpoint, tracked between frames.
///
/// The position is in the rig's own local frame, which is the frame `RigMutation`'s limb targets
/// are written in — so the whole thing composes with the walk cycle and the emote poses without
/// anybody having to convert anything.
struct LimbState {
    var profile: LimbProfile
    let limb: Limb

    /// Where the endpoint is now.
    private(set) var position: SIMD3<Float>
    /// How fast it is going, local units per second. This is the thing a minigame used to have
    /// to keep for itself — the tennis game derived racket-head speed by remembering last
    /// frame's hand position — and it is why "nothing outside here tracks limb velocity" is
    /// worth stating as a rule.
    private(set) var velocity: SIMD3<Float> = .zero

    /// What the caller last asked for, before the reach clamp. Nil means released.
    private(set) var request: SIMD3<Float>?
    /// The same ask, clamped into reach — what the limb is actually chasing.
    private(set) var target: SIMD3<Float>?

    /// 0 the rig's own animation owns this limb, 1 the motor does. Eased, so engaging and
    /// releasing are both a hand-over rather than a snap.
    private(set) var blend: Float = 0

    init(limb: Limb, profile: LimbProfile) {
        self.limb = limb
        self.profile = profile
        self.position = limb.neutral
    }

    var isDriven: Bool { request != nil }
    var isEngaged: Bool { blend > 0.0001 }

    /// How far outside its reach the caller's ask was, in local units. Zero when the ask was
    /// reachable. A minigame that cares whether a swing can actually get there reads this.
    var strain: Float {
        guard let request, let target else { return 0 }
        return simd_length(request - target)
    }

    /// How far the endpoint still is from what it is chasing.
    var error: Float {
        guard let target else { return 0 }
        return simd_length(target - position)
    }

    /// Close enough that a caller waiting on the limb can stop waiting.
    func hasArrived(within tolerance: Float = 0.6) -> Bool {
        guard target != nil else { return true }
        return error <= tolerance
    }

    mutating func drive(to point: SIMD3<Float>, speed: Float? = nil) {
        request = point
        target = profile.reachable(point, from: limb.root)
        if let speed { profile.maxSpeed = speed }
    }

    mutating func release() {
        request = nil
        target = nil
    }

    /// Puts the endpoint somewhere with no travel — a teleport, or a match starting.
    mutating func reset(to point: SIMD3<Float>? = nil) {
        position = point ?? limb.neutral
        velocity = .zero
        request = nil
        target = nil
        blend = 0
    }

    /// Where the rig's own animation has this limb this frame. The motor feeds it back in while
    /// it is not driving, so that the moment it *does* take over it starts from where the limb
    /// visibly is rather than from wherever it was left months of frames ago.
    mutating func observeRigPose(_ point: SIMD3<Float>) {
        guard blend <= 0.0001 else { return }
        position = point
        velocity = .zero
    }

    mutating func step(dt: Double) {
        let step = Float(dt)
        guard step > 0 else { return }

        guard let target else {
            blend = max(0, blend - step / Float(max(profile.releaseTime, 1e-3)))
            velocity *= max(0, 1 - step * 8)
            return
        }

        // Chase the target: a proportional approach speed, capped by what the limb can do, and
        // reached through a bounded acceleration so the hand has weight.
        let toTarget = target - position
        let distance = simd_length(toTarget)
        var desired = SIMD3<Float>.zero
        if distance > 1e-5 {
            // `distance / step` is the speed that would arrive exactly this frame; never ask
            // for more than that, or a limb inside its approach radius overshoots and rings.
            let arrival = min(profile.maxSpeed, min(distance * profile.approachGain, distance / step))
            desired = toTarget / distance * arrival
        }

        let change = desired - velocity
        let magnitude = simd_length(change)
        if magnitude > 1e-6 {
            velocity += change / magnitude * min(profile.acceleration * step, magnitude)
        }

        position += velocity * step
        // The endpoint itself is held inside the reach shell, not just the target: a limb
        // carrying speed towards full extension would otherwise sail past it for a frame and be
        // yanked back by the IK's own clamp, which reads as a twitch.
        position = profile.reachable(position, from: limb.root)

        blend = min(1, blend + step / Float(max(profile.engageTime, 1e-3)))
    }
}
