import Foundation

/// Routes the game's sound events onto `SoundManager`.
///
/// The JS parks a handle on the object that started the sound (`sourceObj.activeAudio`,
/// `events.js:104`) and on the player proxy for the walking loop and the active emote
/// (`main.js:292-303`). The port keeps the same three channels, keyed by source id, so the
/// stop calls the game already makes land on the right sound.
final class GameAudio {
    private let sounds = SoundManager()

    /// One effect per source object or NPC, matching `sourceObj.activeAudio`.
    private var perSource: [Int: SoundManager.Handle] = [:]

    private var walking: SoundManager.Handle?
    private var emote: SoundManager.Handle?

    // MARK: - Event sounds

    /// A `play_sound` event. The map's own tree gets the looping background track; anything
    /// else is a one-shot that replaces whatever that source was already playing.
    func play(sourceId: Int, path: String, volume: Double, isBackground: Bool) {
        if isBackground {
            sounds.playBackground(path, volume: volume)
            return
        }
        perSource[sourceId]?.pause()
        perSource[sourceId] = sounds.playPooled(path, volume: volume)
    }

    /// Leaving a trigger zone, walking out of an NPC's radius, or changing map.
    func stop(sourceId: Int) {
        perSource.removeValue(forKey: sourceId)?.pause()
    }

    func stopBackground() {
        sounds.stopBackground()
    }

    // MARK: - Player channels

    /// The footstep loop. Started on the first moving frame and re-rated as the player breaks
    /// into a run, exactly as `main.js:456-461` does.
    func setWalking(active: Bool, isRunning: Bool) {
        if active {
            if walking == nil {
                walking = sounds.playPooled("/media/walking.mp3", volume: 1, loop: true)
            }
            walking?.setRate(isRunning ? 1.3 : 1.0)
        } else {
            walking?.pause()
            walking = nil
        }
    }

    /// `clearEmoteAudio` (`main.js:291-296`) — a half-second fade, not a hard stop.
    func clearEmoteAudio() {
        emote?.fadeOut(durationMs: 500)
        emote = nil
    }

    /// The sound an emote plays as it starts. Emote definitions land in Phase 6; this is the
    /// channel they will use.
    func playEmoteSound(_ path: String) {
        clearEmoteAudio()
        emote = sounds.playPooled(path, volume: 1)
    }

    /// One-off UI sound with no source to hang it on — the `map_change_rejected` buzzer
    /// (`network.js:180`), and the minigames' racket hits, which vary their playback rate to
    /// stop a rally sounding like a metronome (`tennis.js:1525-1526`).
    func playEffect(_ path: String, volume: Double = 1, rate: Double = 1) {
        let handle = sounds.playPooled(path, volume: volume)
        if rate != 1 { handle.setRate(rate) }
    }

    // MARK: - Lifecycle

    /// Backgrounding the app silences everything; the map's `on_enter` restarts the music
    /// on the next `init`, and the loops restart on demand.
    func suspend() {
        walking = nil
        emote = nil
        perSource.removeAll()
        sounds.stopAll()
    }
}
