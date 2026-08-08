import Foundation

/// Everything the simulation needs from outside itself: the socket, and the UI and audio
/// layers.
///
/// Every method has a do-nothing default below, which is what lets the macOS editor adopt the
/// protocol without an audio stack or a dialog layer to hand the calls to — it implements the
/// two it cares about and inherits the silence for the rest.
protocol GameStateDelegate: AnyObject {
    func gameStateSyncPlayer(_ character: GameCharacter)
    func gameStateSendLog(message: String, npcId: Int)

    func gameStateShowDialog(_ request: DialogRequest)
    func gameStateHideDialog()
    func gameStateShowAvatar(sourceId: Int, name: String?, imagePath: String)
    func gameStateHideAvatar()
    /// Walking out of an NPC's radius: its portrait animates away and any dialog it raised
    /// closes. Port of `cleanupNpcUI` (`ui.js:22`).
    func gameStateCleanupNPCUI(sourceId: Int)
    func gameStateDidSay(sourceId: Int, name: String?, message: String)
    func gameStatePlaySound(sourceId: Int, path: String, volume: Double, isBackground: Bool)
    func gameStateStopSound(sourceId: Int)
    func gameStateStopBackgroundSound()
    /// The footstep loop, re-rated when the player breaks into a run (`main.js:453-466`).
    func gameStateSetWalkingAudio(active: Bool, isRunning: Bool)
    /// `clearEmoteAudio` — the emote's own sound fades out when the emote ends.
    func gameStateClearEmoteAudio()

    /// A pooled one-shot with a playback rate — the minigames' racket hits.
    func gameStatePlayEffect(path: String, volume: Double, rate: Double)
    func gameStateChangeMap(_ mapId: Int)
    func gameStateAwardBadge(_ badge: String)

    /// The map turned out to be a minigame: hand the screen over to it.
    func gameStateDidStartMinigame(_ minigame: Minigame)
    func gameStateDidEndMinigame()
}

extension GameStateDelegate {
    func gameStateShowDialog(_ request: DialogRequest) {}
    func gameStateHideDialog() {}
    func gameStateShowAvatar(sourceId: Int, name: String?, imagePath: String) {}
    func gameStateHideAvatar() {}
    func gameStateCleanupNPCUI(sourceId: Int) {}
    func gameStateDidSay(sourceId: Int, name: String?, message: String) {}
    func gameStatePlaySound(sourceId: Int, path: String, volume: Double, isBackground: Bool) {}
    func gameStateStopSound(sourceId: Int) {}
    func gameStateStopBackgroundSound() {}
    func gameStateSetWalkingAudio(active: Bool, isRunning: Bool) {}
    func gameStateClearEmoteAudio() {}
    func gameStatePlayEffect(path: String, volume: Double, rate: Double) {}
    func gameStateChangeMap(_ mapId: Int) {}
    func gameStateAwardBadge(_ badge: String) {}
    func gameStateDidStartMinigame(_ minigame: Minigame) {}
    func gameStateDidEndMinigame() {}
}
