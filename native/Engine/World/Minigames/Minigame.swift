import Foundation

/// A map whose `import` field names a script instead of describing a world (`maps.json` id 4,
/// Tennis). `main.js:721-734` clears the game loop and hands the frame over to that module;
/// this is the same handover.
protocol Minigame: AnyObject {
    /// False when the game draws itself rather than being drawn by the Metal renderer. Tennis
    /// is a 2D canvas game in the web build and stays one here.
    var usesWorldRenderer: Bool { get }

    func start()
    /// One frame of simulation. `dt` is already clamped to 100 ms, as `gameloop.js:83` does.
    func update(dt: Double)
    func stop()
}

/// What a minigame needs from the app around it: the socket, the sound engine and the dialog.
protocol MinigameHost: AnyObject {
    func minigameShowDialog(_ text: String, onConfirm: @escaping () -> Void)
    func minigameChangeMap(_ mapId: Int)
    func minigameAwardBadge(_ badge: String)
    func minigamePlayBackground(path: String, volume: Double)
    /// `playPooled` followed by `setRate` — folded into one call so the `World` layer never
    /// holds an audio handle.
    func minigamePlayEffect(path: String, volume: Double, rate: Double)
    func minigameStopBackground()
}

extension MinigameHost {
    func minigamePlayEffect(path: String, volume: Double) {
        minigamePlayEffect(path: path, volume: volume, rate: 1)
    }
}

enum MinigameKind: String {
    case tennis

    /// `mapData.import` is a module URL — `/src/minigames/tennis.js`.
    init?(importPath: String) {
        let name = (importPath as NSString).lastPathComponent
        guard let kind = MinigameKind(rawValue: (name as NSString).deletingPathExtension) else {
            return nil
        }
        self = kind
    }
}
