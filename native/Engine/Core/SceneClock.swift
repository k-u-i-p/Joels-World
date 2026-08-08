import Foundation

/// **What time the animation thinks it is**, as opposed to how long the last frame took.
///
/// Two things in the engine ask for the wall clock rather than for `dt`: the rig's idle
/// breathing and sway (`CharacterRig.pose(time:)`), and the emote system, which measures a
/// pose's age against `EmoteState.startTime`. That is fine in a game — nobody can tell a breath
/// apart from the same breath a fifth of a second later — and no good at all in a tool whose
/// job is to notice that a walk cycle changed, because the same character rendered twice never
/// comes out the same twice.
///
/// So both read this instead. It is the wall clock unless something has pinned it, and the only
/// thing that pins it is the character lab, which drives it off its own scrubbable timeline.
/// Frame *n* of a take is then the same picture on every run, which is what makes a filmstrip
/// worth diffing.
///
/// Not `#if DEBUG`: the lab is its own target, and gating this would leave the lab unbuildable
/// in Release. The cost in the game is a nil check per frame against a variable nothing there
/// ever writes.
enum SceneClock {
    /// Seconds since 1970, or nil for the wall clock. Set only by `CharacterLabScene`.
    static var pinned: Double?

    /// Seconds since 1970.
    static var now: Double {
        pinned ?? Date().timeIntervalSince1970
    }

    /// Milliseconds since 1970, rounded — the units `EmoteState.startTime` is in.
    static var nowMilliseconds: Double {
        (now * 1000).rounded()
    }
}
