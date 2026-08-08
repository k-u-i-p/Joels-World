import AppKit

/// The game's look, in AppKit. The twin of the iOS target's `Theme`.
///
/// Both read their values from `Palette` and their display face from `DisplayFont`, so the
/// editor's copy of the game UI cannot drift from the game's by a shade or a font size — only
/// the framework types differ.
enum AdminTheme {

    // MARK: - Palette

    static let panelDark = NSColor(rgb: Palette.panelDark)
    static let primaryHover = NSColor(rgb: Palette.primaryHover)
    static let success = NSColor(rgb: Palette.success)
    static let danger = NSColor(rgb: Palette.danger)
    static let portraitBorder = NSColor(rgb: Palette.portraitBorder)

    static let glassBorder = NSColor(white: 1, alpha: Palette.glassBorderAlpha)
    static let chatRowBackground = NSColor(white: 1, alpha: Palette.chatRowAlpha)

    // MARK: - Fonts

    /// `font-family: 'Pricedown'`, or a heavy rounded system face when it was not staged.
    static func display(_ size: CGFloat) -> NSFont {
        if let name = DisplayFont.postScriptName, let font = NSFont(name: name, size: size) {
            return font
        }
        let base = NSFont.systemFont(ofSize: size, weight: .heavy)
        let rounded = base.fontDescriptor.withDesign(.rounded)
        return rounded.flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }

    static func body(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }

    // MARK: - Components

    /// `.glass-panel` — `backdrop-filter: blur(14px)` with a hairline white border. AppKit's
    /// `.hudWindow` material is the closest stock equivalent.
    static func glassPanel(cornerRadius: CGFloat = 12) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .withinWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 1
        view.layer?.borderColor = glassBorder.cgColor
        return view
    }

    /// The CSS `text-shadow` behind the map name and the nameplates. `NSAttributedString` has
    /// no four-way shadow, so a negative stroke width stands in — it fills *and* strokes.
    static func outlinedText(_ text: String, size: CGFloat) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .bold),
            .foregroundColor: NSColor.white,
            .strokeColor: NSColor.black.withAlphaComponent(0.8),
            .strokeWidth: -3.0,
        ])
    }
}

extension NSColor {
    /// The `0xrrggbb` form `Palette` stores. Distinct from `init?(hex:)` in `AdminControls`,
    /// which parses the `"#rrggbb"` strings the map JSON is authored in.
    convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xff) / 255,
                  green: CGFloat((rgb >> 8) & 0xff) / 255,
                  blue: CGFloat(rgb & 0xff) / 255,
                  alpha: 1)
    }
}
