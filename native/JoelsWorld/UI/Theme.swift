import CoreText
import UIKit

/// The look of the UI layer, ported from `style.css`.
///
/// The web build leans on `backdrop-filter: blur(14px)` for its panels; the native equivalent
/// is `UIVisualEffectView`, so `glassPanel()` returns one already tinted to the same
/// `rgba(87,87,87,0.5)` the CSS uses.
enum Theme {

    // MARK: - Palette (`style.css :root`)

    static let bgPrimary = UIColor(hex: Palette.bgPrimary)
    static let panelDark = UIColor(hex: Palette.panelDark)
    static let primary = UIColor(hex: Palette.primary)
    static let primaryHover = UIColor(hex: Palette.primaryHover)
    static let success = UIColor(hex: Palette.success)
    static let danger = UIColor(hex: Palette.danger)
    static let warning = UIColor(hex: Palette.warning)
    static let textMuted = UIColor(hex: Palette.textMuted)
    static let portraitBorder = UIColor(hex: Palette.portraitBorder)

    static let glassTint = UIColor(white: Palette.glassTintWhite, alpha: Palette.glassTintAlpha)
    static let glassBorder = UIColor(white: 1, alpha: Palette.glassBorderAlpha)
    static let overlayScrim = UIColor(white: 0, alpha: Palette.scrimAlpha)
    static let chatRowBackground = UIColor(white: 1, alpha: Palette.chatRowAlpha)

    // MARK: - Fonts

    /// `font-family: 'Pricedown'`, registered out of the staged assets by `DisplayFont` so the
    /// editor gets the same face. Falls back to a heavy rounded system font if it is missing.
    static func display(_ size: CGFloat) -> UIFont {
        if let name = DisplayFont.postScriptName, let font = UIFont(name: name, size: size) {
            return font
        }
        let base = UIFont.systemFont(ofSize: size, weight: .heavy)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }

    static func body(_ size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        .systemFont(ofSize: size, weight: weight)
    }

    // MARK: - Components

    /// `.glass-panel` — translucent, blurred, hairline white border.
    static func glassPanel(cornerRadius: CGFloat = 12) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
        view.backgroundColor = glassTint
        view.layer.cornerRadius = cornerRadius
        view.layer.cornerCurve = .continuous
        view.clipsToBounds = true
        view.layer.borderWidth = 1
        view.layer.borderColor = glassBorder.cgColor
        return view
    }

    /// `.dialog-header` — Pricedown, centred, with the CSS text shadow.
    static func headerLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = display(32)
        label.textColor = .white
        label.textAlignment = .center
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.8
        label.layer.shadowRadius = 2
        label.layer.shadowOffset = CGSize(width: 1, height: 1)
        return label
    }

    /// Opts a button out of the `UIButton.Configuration` system.
    ///
    /// System buttons carry a default configuration on current iOS, and a configuration takes
    /// precedence over `setTitle(_:for:)` — so a title set after creation is silently ignored.
    /// Every button here is styled by hand, so the configuration buys nothing and costs the
    /// ability to change a label ("Yes" → "OK", "Start Game" → spinner).
    static func makePlainButton() -> UIButton {
        let button = UIButton(type: .system)
        button.configuration = nil
        return button
    }

    /// `.btn` in one of its themed variants.
    static func button(title: String, color: UIColor, filled: Bool = false) -> UIButton {
        let button = makePlainButton()
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = body(15, weight: .bold)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = filled ? color : color.withAlphaComponent(0.4)
        button.layer.cornerRadius = 8
        button.layer.cornerCurve = .continuous
        return button
    }

    /// `.dialog-close-btn` — the round × that hangs off a panel's top-right corner.
    static func closeButton() -> UIButton {
        let button = makePlainButton()
        button.setTitle("×", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 28, weight: .regular)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = UIColor(white: 1, alpha: 0.2)
        button.layer.cornerRadius = 20
        button.layer.borderWidth = 1
        button.layer.borderColor = glassBorder.cgColor
        return button
    }

    /// The CSS `text-shadow` used on the nameplates: a 1 px black outline on all four
    /// diagonals. `NSAttributedString` has no four-way shadow, so it is drawn as a stroke.
    static func outlinedText(_ text: String, size: CGFloat) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: size, weight: .bold),
            .foregroundColor: UIColor.white,
            .strokeColor: UIColor.black.withAlphaComponent(0.8),
            // Negative width fills *and* strokes, which is what the CSS shadow looks like.
            .strokeWidth: -3.0,
        ])
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xff) / 255,
                  green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255,
                  alpha: 1)
    }
}
