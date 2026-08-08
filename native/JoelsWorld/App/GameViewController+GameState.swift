import UIKit

/// Everything the simulation asks of the app around it.
///
/// `GameState` runs the world without knowing there is a screen; this is the whole of what it
/// can reach out and do — put a sound on, raise a dialog, hand a frame upstream. Each one is a
/// single forward to the audio, network or UI object that owns that job, which is the point:
/// the simulation stays testable and the view controller stays the only thing wiring them.
extension GameViewController: GameStateDelegate {
    func gameStateSyncPlayer(_ character: GameCharacter) {
        network.syncPlayer(character)
    }

    func gameStateSendLog(message: String, npcId: Int) {
        Log.world("Log → npc \(npcId): \(message)")
        network.sendLog(message: message, npcId: npcId)
    }

    // MARK: - Dialogs and portraits

    func gameStateShowDialog(_ request: DialogRequest) {
        dialog.present(request)
        #if DEBUG
        debug.dialogWasShown(request)
        #endif
    }

    func gameStateHideDialog() {
        dialog.dismiss()
    }

    func gameStateShowAvatar(sourceId: Int, name: String?, imagePath: String) {
        Log.world("Avatar: \(name ?? "NPC") (\(sourceId)) \(imagePath)")
        hud.showAvatar(sourceId: sourceId, name: name, imagePath: imagePath)
    }

    func gameStateHideAvatar() {
        hud.hideAvatar(sourceId: nil)
    }

    func gameStateCleanupNPCUI(sourceId: Int) {
        hud.hideAvatar(sourceId: sourceId)
        dialog.dismiss()
    }

    func gameStateDidSay(sourceId: Int, name: String?, message: String) {
        Log.world("Say: \(name ?? "NPC") (\(sourceId)): \(message)")
    }

    // MARK: - Audio

    func gameStatePlaySound(sourceId: Int, path: String, volume: Double, isBackground: Bool) {
        Log.world(String(format: "Sound%@: %@ @ %.2f (source %d)",
                         isBackground ? " (background)" : "", path, volume, sourceId))
        audio.play(sourceId: sourceId, path: path, volume: volume, isBackground: isBackground)
    }

    func gameStateStopSound(sourceId: Int) {
        audio.stop(sourceId: sourceId)
    }

    func gameStateStopBackgroundSound() {
        audio.stopBackground()
    }

    func gameStateSetWalkingAudio(active: Bool, isRunning: Bool) {
        audio.setWalking(active: active, isRunning: isRunning)
    }

    func gameStateClearEmoteAudio() {
        audio.clearEmoteAudio()
    }

    func gameStatePlayEffect(path: String, volume: Double, rate: Double) {
        audio.playEffect(path, volume: volume, rate: rate)
    }

    // MARK: - Upstream requests

    func gameStateChangeMap(_ mapId: Int) {
        Log.world("Requesting map change to \(mapId)")
        network.sendChangeMap(mapId)
    }

    func gameStateAwardBadge(_ badge: String) {
        Log.world("Claiming badge: \(badge)")
        network.sendAwardBadge(badge)
    }

    // MARK: - Minigames

    /// The minigame takes the screen: the joystick and the chat HUD go away, the map button
    /// becomes the exit button, and the game's own surface comes up (`tennis.js:662-693`).
    func gameStateDidStartMinigame(_ minigame: Minigame) {
        joystick.isHidden = true
        hud.isHidden = true
        buttons.setMinigameMode(true)

        if let game = minigame as? TennisGame {
            tennis.present(game: game)
        } else if let game = minigame as? Tennis3DGame {
            // Nothing to hide the world behind: this one *is* the world, drawn by the same
            // renderer as the school. Only the score furniture comes up.
            tennis3d.present(game: game)
        }
        #if DEBUG
        debug.minigameDidStart(minigame)
        #endif
    }

    func gameStateDidEndMinigame() {
        #if DEBUG
        debug.minigameDidEnd()
        #endif
        tennis.dismiss()
        tennis3d.dismiss()
        buttons.setMinigameMode(false)
        joystick.isHidden = false
        hud.isHidden = false
    }
}
