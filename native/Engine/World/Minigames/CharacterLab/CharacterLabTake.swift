#if DEBUG
import Foundation

/// Where the camera stands. Yaw is measured so that **0 looks at a character facing +X from
/// the side**, and a positive yaw walks the camera round towards their front.
///
/// The pitch ceiling is `Camera.setPitch`'s π/2.1; `top` is not quite zero because a camera
/// looking exactly straight down gimbal-locks.
enum CharacterLabView: String, CaseIterable {
    case side
    case threeQuarter
    case front
    case back
    case top

    var title: String {
        switch self {
        case .side: return "Side"
        case .threeQuarter: return "Three-quarter"
        case .front: return "Front"
        case .back: return "Back"
        case .top: return "Overhead"
        }
    }

    var yaw: Double {
        switch self {
        case .side: return 0
        case .threeQuarter: return 0.9
        case .front: return .pi / 2
        case .back: return -.pi / 2
        case .top: return 0
        }
    }

    /// How far the camera is tipped from straight down. The overworld's near-overhead camera is
    /// the one angle a rig cannot be judged from, so these are all well over — but not at the
    /// π/2.1 ceiling, because a camera at ground level cannot be composed: see the note in
    /// `CharacterLabScene.updateCamera` about why the drop stops working near the horizontal.
    var pitch: Double {
        switch self {
        case .side: return 1.20
        case .threeQuarter: return 1.10
        case .front: return 1.15
        case .back: return 1.15
        case .top: return 0.05
        }
    }
}

/// **What the subject is asked to do.** Everything is a pure function of the time into the
/// take, so replaying a take from zero always produces the same frame at the same instant —
/// which is what lets the scrubber scrub and the filmstrip be diffed against yesterday's.
///
/// `throttle` is a fraction of `LocomotionProfile.player.maxSpeed`, which is the **sprint**.
/// About 0.45 is a walk and 1.0 is flat out; the gait's `run` term crosses over in between.
enum CharacterLabMotion {
    /// Stand there. Not "do nothing" — idle breathing and sway are still running.
    case still
    /// Straight line along +X, facing the way they are going.
    case walk(throttle: Double)
    /// Sideways along +Y with the chest pinned to +X, which is what a tennis player does.
    case strafe(throttle: Double)
    /// Backwards along −X with the chest still pinned forwards.
    case backpedal(throttle: Double)
    /// On the spot, no travel. Degrees a second is a *request* — `profile.turnRate` decides
    /// what actually happens, and the difference is the point.
    case turnOnTheSpot(degreesPerSecond: Double)
    /// A circle of this radius in metres, taken at this throttle. Turning while moving is the
    /// case that leans the body and trails the waist.
    case circle(radiusMetres: Double, throttle: Double)
    /// Sprint out, stop dead, sprint back. The bracing step and the counterweight live here.
    case shuttle(throttle: Double, legSeconds: Double)
    /// Full-speed changes of direction, every `period` seconds.
    case zigzag(throttle: Double, period: Double)
    /// Stand still and jump, on the beat.
    case jump(everySeconds: Double)
}

/// One thing worth looking at, with the camera and the clock it wants.
struct CharacterLabTake {
    /// Stable, lower case, no spaces — this is what `-labtake` takes.
    let id: String
    let title: String
    /// One line on what is being tested. Printed under the frame in a filmstrip, so a picture
    /// arrives with its own caption instead of needing one written by hand.
    let watchFor: String
    /// One loop of the take. The scrubber's range and the filmstrip's span.
    let seconds: Double
    let motion: CharacterLabMotion
    /// Played on the subject for the whole take, with its start pinned to the take's start.
    let emote: String?
    let view: CharacterLabView

    init(id: String,
         title: String,
         watchFor: String,
         seconds: Double,
         motion: CharacterLabMotion = .still,
         emote: String? = nil,
         view: CharacterLabView = .threeQuarter) {
        self.id = id
        self.title = title
        self.watchFor = watchFor
        self.seconds = seconds
        self.motion = motion
        self.emote = emote
        self.view = view
    }

    // MARK: - Driving

    /// Asks the motor for whatever this take wants at `time` seconds in. Called once per
    /// fixed sub-step; the motor is stepped by the scene afterwards.
    ///
    /// `speedScale` is the lab's throttle override — the slider — applied on top of whatever
    /// the take asked for, so one take covers a crawl to a sprint without needing eleven.
    func drive(_ motor: CharacterMotor, at time: Double, speedScale: Double) {
        let top = motor.profile.maxSpeed

        func hold(_ vx: Double, _ vy: Double, facing: Double?) {
            motor.driveCharacter(velocityX: vx, velocityY: vy, facing: facing)
        }

        switch motion {
        case .still:
            motor.holdPosition()

        case let .walk(throttle):
            hold(top * throttle * speedScale, 0, facing: nil)

        case let .strafe(throttle):
            hold(0, top * throttle * speedScale, facing: 0)

        case let .backpedal(throttle):
            hold(-top * throttle * speedScale, 0, facing: 0)

        case let .turnOnTheSpot(degreesPerSecond):
            motor.holdPosition()
            motor.faceTowards(time * degreesPerSecond * speedScale)

        case let .circle(radiusMetres, throttle):
            let speed = top * throttle * speedScale
            let radius = CharacterLabScene.metres(radiusMetres)
            // Angular rate that keeps the speed honest, so the slider changes the pace and not
            // the shape of the path.
            let omega = speed / max(radius, 1)
            hold(speed * cos(omega * time), speed * sin(omega * time), facing: nil)

        case let .shuttle(throttle, legSeconds):
            let speed = top * throttle * speedScale
            // Four beats: out, stop, back, stop. The stops are where the interesting frames are.
            let beat = Int(floor(time / legSeconds)) % 4
            switch beat {
            case 0: hold(speed, 0, facing: 0)
            case 1: motor.holdPosition(); motor.faceTowards(0)
            case 2: hold(-speed, 0, facing: 0)
            default: motor.holdPosition(); motor.faceTowards(0)
            }

        case let .zigzag(throttle, period):
            let speed = top * throttle * speedScale
            let leg = Int(floor(time / period)) % 2
            hold(speed * 0.6, leg == 0 ? speed : -speed, facing: nil)

        case let .jump(everySeconds):
            motor.holdPosition()
            motor.faceTowards(0)
            // The take's clock is fixed-stepped, so "did we just cross a beat" is exact rather
            // than a tolerance around one.
            if !motor.isAirborne, time.truncatingRemainder(dividingBy: everySeconds) < 0.02 {
                motor.gravity = GameState.jumpGravity
                motor.jump(speed: GameState.jumpSpeed)
            }
        }
    }

    // MARK: - The catalogue

    /// Every take, in the order the lab steps through them: standing, then the gaits, then the
    /// hard cases, then one per emote.
    static let all: [CharacterLabTake] = movement + emotes

    static let movement: [CharacterLabTake] = [
        CharacterLabTake(id: "stand",
                         title: "Standing",
                         watchFor: "Breathing and sway. Arms hang with a bend; feet flat, no hover, no sink.",
                         seconds: 6,
                         motion: .still),
        CharacterLabTake(id: "creep",
                         title: "Creeping",
                         watchFor: "The slowest gait that is still a gait — short stride, low knee, almost no bounce.",
                         seconds: 6,
                         motion: .walk(throttle: 0.2),
                         view: .side),
        CharacterLabTake(id: "walk",
                         title: "Walking",
                         watchFor: "Heel down under the hip, opposite arm forward, both feet on the floor at the ends of the stride.",
                         seconds: 6,
                         motion: .walk(throttle: 0.45),
                         view: .side),
        CharacterLabTake(id: "run",
                         title: "Sprinting",
                         watchFor: "Longer stride, high knee, a flight phase — and the torso leaning into it.",
                         seconds: 6,
                         motion: .walk(throttle: 1.0),
                         view: .side),
        CharacterLabTake(id: "strafe",
                         title: "Side-stepping",
                         watchFor: "Chest stays square to +X while the feet go sideways. No pirouette.",
                         seconds: 6,
                         motion: .strafe(throttle: 0.6),
                         view: .front),
        CharacterLabTake(id: "backpedal",
                         title: "Back-pedalling",
                         watchFor: "Walking backwards, not a forward walk played in reverse.",
                         seconds: 6,
                         motion: .backpedal(throttle: 0.5),
                         view: .side),
        CharacterLabTake(id: "turn",
                         title: "Turning on the spot",
                         watchFor: "Shoulders trail the hips, feet shuffle rather than skate, no sliding.",
                         seconds: 6,
                         motion: .turnOnTheSpot(degreesPerSecond: 180),
                         view: .top),
        CharacterLabTake(id: "circle",
                         title: "Running a circle",
                         watchFor: "Body banks into the turn; the waist trails it. Inside foot lands inside the line.",
                         seconds: 8,
                         motion: .circle(radiusMetres: 3, throttle: 0.8),
                         view: .threeQuarter),
        CharacterLabTake(id: "shuttle",
                         title: "Sprint, stop, sprint back",
                         watchFor: "A braced foot out in front to stop against, and the counterweight as it sets off again.",
                         seconds: 8,
                         motion: .shuttle(throttle: 1.0, legSeconds: 2),
                         view: .side),
        CharacterLabTake(id: "zigzag",
                         title: "Cutting side to side",
                         watchFor: "The bracing step on the change of direction, and which foot takes it.",
                         seconds: 8,
                         motion: .zigzag(throttle: 0.9, period: 1.2),
                         view: .threeQuarter),
        CharacterLabTake(id: "jump",
                         title: "Jumping",
                         watchFor: "Take-off, height, and both feet finding the floor again on landing.",
                         seconds: 6,
                         motion: .jump(everySeconds: 2),
                         view: .side),
    ]

    /// One take per emote, its length taken from the emote's own duration so a filmstrip spans
    /// the whole pose rather than the first second of it.
    static let emotes: [CharacterLabTake] = Emotes.names.map { name in
        let duration = (Emotes.definition(name)?.duration ?? 2000) / 1000
        return CharacterLabTake(id: "emote-\(name)",
                                title: "Emote: \(name)",
                                watchFor: "The whole pose, start to finish, including any props it spawns.",
                                seconds: min(max(duration, 2), 12),
                                motion: .still,
                                emote: name,
                                view: .threeQuarter)
    }

    static func take(id: String) -> CharacterLabTake? {
        all.first { $0.id == id }
    }
}
#endif
