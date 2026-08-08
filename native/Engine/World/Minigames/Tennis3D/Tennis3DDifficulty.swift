import Foundation

/// How good Alex is, as a thing Joel can choose rather than a constant only a launch argument
/// could reach.
///
/// `Tennis3DGame.Tuning.difficulty` is still the single number the simulation reads — her
/// reaction time, her positioning error and her top speed all come off it. This is the three
/// places on that dial worth naming, plus somewhere to remember which one was picked.
///
/// The numbers come from the balance runs in `HANDOFF-tennis3d-part2.md`: measured against the
/// `-tennis3ddemo` bot — which reads the ball perfectly and has no reaction time, so it is a
/// good deal better than a ten-year-old — 0.5 lost every point and 1.0 lost about a third.
enum Tennis3DDifficulty: Int, CaseIterable {
    case easy = 0
    case normal = 1
    case hard = 2

    /// What `Tuning.difficulty` becomes.
    var value: Double {
        switch self {
        case .easy: return 0.35
        case .normal: return 0.6
        case .hard: return 0.9
        }
    }

    /// The button label. Named for Alex rather than for the player, because "hard" reads as
    /// "this is hard for me" and what it actually means is "she is good".
    var title: String {
        switch self {
        case .easy: return "Easy"
        case .normal: return "Normal"
        case .hard: return "Hard"
        }
    }

    /// One line of what changes, for the match panel.
    var blurb: String {
        switch self {
        case .easy: return "Alex is having an off day."
        case .normal: return "Alex plays a decent game."
        case .hard: return "Alex is quick and she means it."
        }
    }

    // MARK: - Remembering it

    private static let storageKey = "tennis3d.difficulty"

    /// The level in force. Persisted, so a choice made at the end of one match is still there
    /// the next time the court is walked onto — including after the app is closed.
    static var current: Tennis3DDifficulty {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: storageKey) != nil else { return .normal }
            return Tennis3DDifficulty(rawValue: defaults.integer(forKey: storageKey)) ?? .normal
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: storageKey) }
    }
}
