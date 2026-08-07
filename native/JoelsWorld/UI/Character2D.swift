import CoreGraphics
import UIKit

/// The 2D humanoid the tennis minigame draws, ported from `characters.js`.
///
/// Everywhere else in the game a character is the procedural 3D rig (`CharacterRig`); tennis is
/// the one screen the web build renders on a 2D canvas, so it calls `drawShoe2D` and
/// `drawHumanoidUpperBody2D` instead. Those two functions are what this file is.
///
/// `tennis.js` passes neither `isVisible` nor `getRaycastEnd`, so the clip-mask occlusion both
/// take in the overworld is not part of this path — the JS falls back to "everything is
/// visible, nothing is cut short" (`characters.js:604-605`), and so does this.
enum Character2D {
    /// `HAIR_COLOR_MAP` (`characters.js:60`).
    static let hairColors: [String: String] = [
        "blonde": "#efca41",
        "grey": "#5d5d5d",
        "black": "#222222",
        "red": "#9a3e10",
        "brown": "#6e2c00",
    ]

    /// One character's colours and head style, as the 2D drawing code reads them.
    struct Appearance {
        var gender: String?
        var head: String?
        var hairColor: String?
        var shirtColor: String?
        var armColor: String?
        var pantsColor: String?
        var shoeColor: String?

        init(_ character: GameCharacter?) {
            gender = character?.gender
            head = character?.head
            hairColor = character?.hair_color
            shirtColor = character?.shirt_color
            armColor = character?.arm_color
            pantsColor = character?.pants_color
            shoeColor = character?.shoe_color
        }
    }

    // MARK: - Shoes

    /// `drawShoe2D` (`characters.js:483-539`).
    static func drawShoe(_ canvas: Canvas2D, x: CGFloat, y: CGFloat, color: String, isLeft: Bool) {
        let dirY: CGFloat = isLeft ? -1 : 1

        canvas.fillStyle = .color(CSS.hex("#7f8c8d"))
        canvas.beginPath()
        canvas.moveTo(x - 2, y - 3.5)
        canvas.lineTo(x + 5.5, y - 3.5)
        canvas.bezierCurveTo(x + 10, y - 3.5 * dirY, x + 10, y + 3.5, x + 5.5, y + 3.5)
        canvas.lineTo(x - 2, y + 3.5)
        // The JS passes six arguments to `quadraticCurveTo`; the last pair is ignored, so the
        // subpath ends on the control point's corner and `fill()` closes it back to the start.
        canvas.quadraticCurveTo(x - 3.5, y + 3.5, x - 3.5, y - 3.5)
        canvas.fill()

        var bodyGrad = canvas.createRadialGradient(x + 2, y - 1 * dirY, 0.5, x + 3, y, 6)
        bodyGrad.addColorStop(0, CSS.shade(color, 40))
        bodyGrad.addColorStop(0.5, CSS.hex(color))
        bodyGrad.addColorStop(1, CSS.shade(color, -40))

        canvas.fillStyle = .gradient(bodyGrad)
        canvas.beginPath()
        canvas.moveTo(x - 1.5, y - 3)
        canvas.lineTo(x + 4.5, y - 3)
        canvas.bezierCurveTo(x + 9, y - 3 * dirY, x + 9, y + 3, x + 4.5, y + 3)
        canvas.lineTo(x - 1.5, y + 3)
        canvas.quadraticCurveTo(x - 2.5, y + 3, x - 2.5, y - 3)
        canvas.fill()

        canvas.fillStyle = .color(CSS.hex("#34495e"))
        canvas.beginPath()
        canvas.moveTo(x + 5, y - 2.5)
        canvas.bezierCurveTo(x + 9, y - 2.5 * dirY, x + 9, y + 2.5, x + 5, y + 2.5)
        canvas.quadraticCurveTo(x + 3.5, y, x + 5, y - 2.5)
        canvas.fill()

        canvas.fillStyle = .color(CSS.shade(color, -20))
        canvas.beginPath()
        canvas.moveTo(x - 1, y - 2)
        canvas.lineTo(x + 3, y - 2.5)
        canvas.lineTo(x + 3, y + 2.5)
        canvas.lineTo(x - 1, y + 2)
        canvas.fill()

        canvas.lineWidth = 1
        canvas.strokeStyle = .color(CSS.white(0.4))
        canvas.beginPath()
        canvas.moveTo(x + 0.5, y - 2); canvas.lineTo(x + 2, y + 2)
        canvas.moveTo(x + 2, y - 2); canvas.lineTo(x + 0.5, y + 2)
        canvas.moveTo(x + 1.5, y - 2); canvas.lineTo(x + 3, y + 2)
        canvas.moveTo(x + 3, y - 2); canvas.lineTo(x + 1.5, y + 2)
        canvas.stroke()

        canvas.lineWidth = 0.5
        canvas.strokeStyle = .color(CSS.white(0.3))
        canvas.beginPath()
        canvas.moveTo(x - 1, y - 2.5)
        canvas.quadraticCurveTo(x + 3, y - 2.5 * dirY, x + 4.5, y - 2.5)
        canvas.stroke()
    }

    // MARK: - Upper body

    /// `drawHumanoidUpperBody2D` (`characters.js:602-756`).
    static func drawUpperBody(_ canvas: Canvas2D, _ appearance: Appearance, _ limbs: Limbs2D) {
        let armOffset: CGFloat = 11
        let armColor = appearance.armColor ?? "#3498db"
        let shirtColor = appearance.shirtColor ?? "#3498db"

        var armGradient = canvas.createLinearGradient(0, -armOffset, 0, limbs.leftArmY)
        armGradient.addColorStop(0, CSS.hex(armColor))
        armGradient.addColorStop(1, CSS.shade(armColor, -30))

        canvas.lineWidth = 5
        canvas.strokeStyle = .gradient(armGradient)
        drawLine(canvas, 0, -armOffset, limbs.leftArmX, limbs.leftArmY)

        var rightArmGradient = canvas.createLinearGradient(0, armOffset, 0, limbs.rightArmY)
        rightArmGradient.addColorStop(0, CSS.hex(armColor))
        rightArmGradient.addColorStop(1, CSS.shade(armColor, -30))
        canvas.strokeStyle = .gradient(rightArmGradient)
        drawLine(canvas, 0, armOffset, limbs.rightArmX, limbs.rightArmY)

        canvas.fillStyle = .gradient(handGradient(canvas, limbs.leftArmX, limbs.leftArmY))
        canvas.beginPath()
        canvas.arc(limbs.leftArmX, limbs.leftArmY, 3, 0, .pi * 2)
        canvas.fill()

        canvas.fillStyle = .gradient(handGradient(canvas, limbs.rightArmX, limbs.rightArmY))
        canvas.beginPath()
        canvas.arc(limbs.rightArmX, limbs.rightArmY, 3, 0, .pi * 2)
        canvas.fill()

        var bodyGradient = canvas.createLinearGradient(-8, 0, 8, 0)
        bodyGradient.addColorStop(0, CSS.hex(shirtColor))
        bodyGradient.addColorStop(0.5, CSS.shade(shirtColor, 20))
        bodyGradient.addColorStop(1, CSS.shade(shirtColor, -40))
        canvas.fillStyle = .gradient(bodyGradient)

        let bodyDepth: CGFloat = appearance.gender == "female" ? 10 : 12
        canvas.beginPath()
        canvas.roundRect(-(bodyDepth / 2), -12, bodyDepth, 24, 6)
        canvas.fill()

        canvas.beginPath()
        canvas.arc(2, 0, 8, 0, .pi * 2)
        var headGradient = canvas.createRadialGradient(0, -2, 2, 2, 0, 8)
        headGradient.addColorStop(0, CSS.hex("#f5d39e"))
        headGradient.addColorStop(0.6, CSS.hex("#e0ab63"))
        headGradient.addColorStop(1, CSS.hex("#a67232"))
        canvas.fillStyle = .gradient(headGradient)
        canvas.fill()

        canvas.lineWidth = 2
        canvas.strokeStyle = .color(CSS.black(0.4))
        canvas.stroke()

        drawHair(canvas, appearance)
    }

    private static func drawLine(_ canvas: Canvas2D,
                                 _ sx: CGFloat, _ sy: CGFloat,
                                 _ ex: CGFloat, _ ey: CGFloat) {
        canvas.beginPath()
        canvas.moveTo(sx, sy)
        canvas.lineTo(ex, ey)
        canvas.stroke()
    }

    private static func handGradient(_ canvas: Canvas2D, _ x: CGFloat, _ y: CGFloat) -> Canvas2D.Gradient {
        var gradient = canvas.createRadialGradient(x, y - 1, 0.5, x, y, 3)
        gradient.addColorStop(0, CSS.hex("#f5d39e"))
        gradient.addColorStop(0.6, CSS.hex("#e0ab63"))
        gradient.addColorStop(1, CSS.hex("#a67232"))
        return gradient
    }

    /// `characters.js:679-755`. A female character with no `hair_color` gets blonde; any colour
    /// the map does not know also falls back to blonde.
    private static func drawHair(_ canvas: Canvas2D, _ appearance: Appearance) {
        var hairColor = appearance.hairColor
        if hairColor == nil, appearance.gender == "female" { hairColor = "blonde" }

        guard var name = hairColor,
              name != "none", name != "bald",
              !(appearance.head?.contains("bald") ?? false)
        else { return }

        name = hairColors[name] ?? hairColors["blonde"]!

        let shine = CSS.shade(name, 30)
        let shadow = CSS.shade(name, -40)

        var hairGradient = canvas.createLinearGradient(-6, -7, 6, 7)
        hairGradient.addColorStop(0, CSS.hex(name))
        hairGradient.addColorStop(0.4, shine)
        hairGradient.addColorStop(1, shadow)
        canvas.fillStyle = .gradient(hairGradient)
        canvas.beginPath()

        let piHalf = CGFloat.pi / 2
        let piOneHalf = CGFloat.pi * 1.5
        let style = appearance.head ?? (appearance.gender == "female" ? "long" : "short")

        if style.contains("short") {
            canvas.arc(1, 0, 7.5, piHalf + 0.3, piOneHalf - 0.3)
            canvas.fill()
        } else if style.contains("spiky") {
            canvas.arc(1, 0, 7.5, piHalf, piOneHalf)
            canvas.fill()
            canvas.beginPath()
            canvas.moveTo(1, -7.5)
            canvas.lineTo(-4, -7)
            canvas.lineTo(-12, -4)
            canvas.lineTo(-6, -2)
            canvas.lineTo(-14, 1)
            canvas.lineTo(-5, 3)
            canvas.lineTo(-11, 6)
            canvas.lineTo(-4, 7)
            canvas.lineTo(1, 7.5)
            canvas.fill()
        } else if style.contains("ponytail") {
            canvas.arc(1, 0, 7.5, piHalf, piOneHalf)
            canvas.fill()
            canvas.beginPath()
            canvas.ellipse(-9, 0, 4, 3, 0, 0, .pi * 2)
            canvas.fill()
        } else if style.contains("messy") {
            canvas.arc(1, 0, 7.5, piHalf, piOneHalf)
            canvas.fill()
            canvas.beginPath()
            canvas.moveTo(1, -7.5)
            canvas.lineTo(-8, -6)
            canvas.lineTo(-6, -3)
            canvas.lineTo(-9, -1)
            canvas.lineTo(-6, 2)
            canvas.lineTo(-8, 5)
            canvas.lineTo(1, 7.5)
            canvas.fill()
        } else {
            canvas.arc(1, 0, 7.5, piHalf, piOneHalf)
            canvas.fill()

            canvas.beginPath()
            canvas.moveTo(1, -5.5)
            canvas.bezierCurveTo(0, -6, -16, -6, -14, -1)
            canvas.bezierCurveTo(-12, 5, -6, 7, -2, 7.5)
            canvas.bezierCurveTo(-1, 7.5, 0, 7.5, 1, 7.5)
            canvas.fill()
        }
    }
}
