import Foundation

/// How many games win the match, as a thing Joel can choose.
///
/// It was a constant, `Tuning.gamesToWinMatch = 2`, and two games is a match that is over in
/// about three minutes. That is the right length for the first time anybody walks onto the court
/// and wants the badge, and it is far too short once the badge is won and the point of playing is
/// the playing. Both are worth having, so both are here.
///
/// The value is read fresh every time a game ends — nothing caches it — so switching mid-match
/// simply changes how many more games are needed. Switching from Long to Short while 2–0 up ends
/// the match at the end of the next game rather than immediately, which is the least surprising
/// of the available behaviours.
enum Tennis3DMatchLength: Int, CaseIterable {
    case short = 0
    case long = 1

    /// Games needed to win the match, and so the badge.
    var games: Int {
        switch self {
        case .short: return 2
        case .long: return 4
        }
    }

    var title: String {
        switch self {
        case .short: return "Short"
        case .long: return "Long"
        }
    }

    /// One line of what it means, for the banner.
    var blurb: String {
        switch self {
        case .short: return "First to 2 games. About three minutes."
        case .long: return "First to 4 games. A proper match."
        }
    }

    // MARK: - Remembering it

    private static let storageKey = "tennis3d.matchLength"

    /// The length in force, persisted the same way the difficulty is — a choice made at the end
    /// of one match is still there the next time the court is walked onto.
    static var current: Tennis3DMatchLength {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: storageKey) != nil else { return .short }
            return Tennis3DMatchLength(rawValue: defaults.integer(forKey: storageKey)) ?? .short
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: storageKey) }
    }
}
