import Foundation

// Where the two things that drive the world from outside `update()` land: the event tree, and
// a minigame that has taken the screen. Both are pure forwarding — everything either one can
// ask for either mutates a character in place or is handed straight on to the delegate.

// MARK: - Event effects

extension GameState: EventInterpreterDelegate {
    func eventShowAvatar(sourceId: Int, name: String?, imagePath: String) {
        delegate?.gameStateShowAvatar(sourceId: sourceId, name: name, imagePath: imagePath)
    }

    func eventSay(sourceId: Int, message: String) {
        setChatBubble(id: sourceId, message: message)

        let name = npcs.first(where: { $0.id == sourceId })?.name
            ?? characters.first(where: { $0.id == sourceId })?.name
        delegate?.gameStateDidSay(sourceId: sourceId, name: name, message: message)
    }

    func eventShowDialog(_ request: DialogRequest) {
        delegate?.gameStateShowDialog(request)
    }

    func eventPlaySound(sourceId: Int, path: String, volume: Double, isBackground: Bool) {
        delegate?.gameStatePlaySound(sourceId: sourceId,
                                     path: path,
                                     volume: volume,
                                     isBackground: isBackground)
    }

    func eventSetEmote(_ emote: EmoteState?, sourceId: Int, targetsPlayer: Bool) {
        if targetsPlayer {
            setPlayerEmote(emote)
        } else {
            setEmote(emote, onCharacterId: sourceId)
        }
    }

    func eventLog(message: String, npcId: Int) {
        delegate?.gameStateSendLog(message: message, npcId: npcId)
    }
}

// MARK: - Minigame host

extension GameState: MinigameHost {
    func minigameShowDialog(_ text: String, onConfirm: @escaping () -> Void) {
        delegate?.gameStateShowDialog(DialogRequest(text: text,
                                                    confirmAction: nil,
                                                    onConfirm: onConfirm))
    }

    func minigameChangeMap(_ mapId: Int) {
        delegate?.gameStateChangeMap(mapId)
    }

    func minigameAwardBadge(_ badge: String) {
        delegate?.gameStateAwardBadge(badge)
    }

    func minigamePlayBackground(path: String, volume: Double) {
        delegate?.gameStatePlaySound(sourceId: -1, path: path, volume: volume, isBackground: true)
    }

    func minigamePlayEffect(path: String, volume: Double, rate: Double) {
        delegate?.gameStatePlayEffect(path: path, volume: volume, rate: rate)
    }

    func minigameStopBackground() {
        delegate?.gameStateStopBackgroundSound()
    }
}
