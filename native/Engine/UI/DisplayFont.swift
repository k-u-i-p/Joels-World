import CoreGraphics
import CoreText
import Foundation

/// `font-family: 'Pricedown'` — the display face behind the headers, the map name and the
/// emote and badge rows.
///
/// Registered at first use out of the staged asset tree rather than either app's own bundle,
/// which is what lets both register the same file. Registration is pure Core Text, so this is
/// the whole of the shared part: each app turns the returned PostScript name into its own
/// `UIFont` or `NSFont`.
enum DisplayFont {
    static let assetPath = "fonts/pricedown.otf"

    /// The registered face's PostScript name, or nil when the font was not staged — in which
    /// case both apps fall back to a heavy system face.
    static var postScriptName: String? {
        registerIfNeeded()
        return name
    }

    private static var name: String?
    private static var attempted = false

    private static func registerIfNeeded() {
        guard !attempted else { return }
        attempted = true

        guard let data = AssetLocator.data(for: assetPath),
              let provider = CGDataProvider(data: data as CFData),
              let font = CGFont(provider)
        else {
            Log.render("Pricedown not staged — the UI falls back to the system display face")
            return
        }
        // Registered at runtime rather than through `UIAppFonts`: both targets generate their
        // Info.plist from build settings, and there is no `INFOPLIST_KEY_` for a font list.
        CTFontManagerRegisterGraphicsFont(font, nil)
        name = font.postScriptName as String?
    }
}
