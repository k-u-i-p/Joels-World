import Foundation

/// `style.css :root`, as plain numbers.
///
/// Neither app can share the other's colour type — `UIColor` and `NSColor` are different
/// classes in frameworks that do not coexist — but they can share the values, which is what
/// stops the editor's chrome drifting away from the game's. `Theme` (UIKit) and `AdminTheme`
/// (AppKit) each build their own colours from these.
enum Palette {
    static let bgPrimary: UInt32 = 0x7bed9f
    static let panelDark: UInt32 = 0x2c3e50
    static let primary: UInt32 = 0x3498db
    static let primaryHover: UInt32 = 0x2980b9
    static let success: UInt32 = 0x2ecc71
    static let danger: UInt32 = 0xe74c3c
    static let warning: UInt32 = 0xf1c40f
    static let textMuted: UInt32 = 0xcbd5e1
    /// The `#ecf0f1` frame around the NPC portrait.
    static let portraitBorder: UInt32 = 0xecf0f1

    /// `rgba(87,87,87,0.5)` — the tint over `backdrop-filter: blur(14px)`.
    static let glassTintWhite: Double = 87.0 / 255.0
    static let glassTintAlpha: Double = 0.5
    static let glassBorderAlpha: Double = 0.3
    static let scrimAlpha: Double = 0.5
    /// The chat rows are very nearly opaque white over the map.
    static let chatRowAlpha: Double = 0.95
}
