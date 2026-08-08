import CoreGraphics
import Foundation
import simd

/// One character's screen-space furniture for this frame.
struct OverlayEntry {
    var id: Int
    var name: String?
    /// Screen position of the character's origin, in points.
    var screen: CGPoint
    /// Nil when the character has said nothing, or said it more than `bubbleLifetime` ago.
    var chatMessage: String?
    var showsNameplate: Bool
}

/// Which characters get a nameplate or a speech bubble this frame, and where each one lands.
///
/// Pure geometry, so both apps run this same pass: the iOS build pools UIKit views over the
/// Metal view (`CharacterOverlayView`) and the editor draws them straight into its Core
/// Graphics overlay (`AdminCharacterOverlay`), but the frustum test, the projection and the
/// five-second bubble window are decided once, here. Port of the positioning loop at
/// `characters.js:1240-1290`.
enum CharacterOverlay {
    /// The web build refuses to draw more than three bubbles in a frame
    /// (`currentFrameChatCount`, `characters.js:1262`).
    static let maxBubblesPerFrame = 3

    /// A bubble lives five seconds from the moment the message arrived.
    static let bubbleLifetime: TimeInterval = 5

    /// How far above the character's origin the nameplate sits, scaled by zoom exactly as the
    /// JS does (`45 * cameraZoom`).
    static func nameOffset(zoom: Double) -> CGFloat { CGFloat(45 * zoom) }

    /// The bubble's tip, likewise (`55 * cameraZoom`).
    static func chatOffset(zoom: Double) -> CGFloat { CGFloat(55 * zoom) }

    /// Everything worth drawing furniture for, already projected. A character that fails the
    /// frustum test is dropped rather than returned hidden — nothing downstream has a use for
    /// an off-screen position.
    static func entries(in state: GameState, viewport: SIMD2<Float>) -> [OverlayEntry] {
        let camera = state.camera
        var out: [OverlayEntry] = []
        out.reserveCapacity(16)

        for subject in state.overlaySubjects {
            // The JS frustum test projects five units above the character's origin.
            let probe = camera.project(worldX: subject.x, worldY: subject.y, z: subject.z + 5,
                                       viewport: viewport)
            guard probe.ndc.z <= 1, abs(probe.ndc.x) <= 1.3, abs(probe.ndc.y) <= 1.3 else { continue }

            let anchor = camera.project(worldX: subject.x, worldY: subject.y, z: subject.z,
                                        viewport: viewport)
            out.append(OverlayEntry(
                id: subject.id,
                name: subject.name,
                screen: CGPoint(x: CGFloat(anchor.screen.x), y: CGFloat(anchor.screen.y)),
                chatMessage: isBubbleLive(chatTime: subject.chatTime) ? subject.chatMessage : nil,
                showsNameplate: !subject.hideNameplate))
        }
        return out
    }

    /// Whether a message posted at `chatTime` is still inside the five-second window.
    static func isBubbleLive(chatTime: TimeInterval?) -> Bool {
        guard let chatTime else { return false }
        return Date.timeIntervalSinceReferenceDate - chatTime < bubbleLifetime
    }
}
