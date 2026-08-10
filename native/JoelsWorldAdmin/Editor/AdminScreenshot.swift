import AppKit
import Metal
import MetalKit

/// `-shot <path> [seconds]` — renders one frame to a PNG and quits.
///
/// The iOS port is verified with `xcrun simctl io screenshot`; there is no equivalent for a
/// Mac app, and `screencapture` needs a Screen Recording grant that a build machine may not
/// have. So the editor grabs its own frame: the Metal drawable is blitted to a readable
/// texture, the AppKit overlay is cached into a bitmap, and the two are composited.
enum AdminScreenshot {
    static var path: String? {
        argument("-shot")
    }

    /// How long to wait after launch before grabbing, so map tiles and models have loaded.
    static var delay: Double {
        argument("-shotdelay").flatMap(Double.init) ?? 6
    }

    static var quitsAfterShot: Bool {
        ProcessInfo.processInfo.arguments.contains("-shot")
    }

    /// `-campitch <radians>` `-camyaw <radians>` `-camzoom <n>` — where the camera stands.
    ///
    /// R/F/Q/E do this interactively, and a held key is no use to a script. Without these a
    /// headless shot is taken from straight overhead, which is the one angle that cannot show
    /// whether a character has a collar, a knee or an elbow. Applied once at launch, so they
    /// compose with the keys rather than replacing them.
    /// `-nooverlays` — start with the editor's boxes and rings switched off, so a scripted shot
    /// shows the world the way the game draws it. View ▸ Show Overlays (⌘O) is the same switch
    /// by hand.
    static var startsWithOverlaysHidden: Bool {
        ProcessInfo.processInfo.arguments.contains("-nooverlays")
    }

    static var cameraPitch: Double? { argument("-campitch").flatMap(Double.init) }
    static var cameraYaw: Double? { argument("-camyaw").flatMap(Double.init) }
    static var cameraZoom: Double? { argument("-camzoom").flatMap(Double.init) }

    private static func argument(_ name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// Composites the whole window: the AppKit chrome and sidebar from `cacheDisplay`, the
    /// captured Metal frame in the map's rectangle, then everything that sits over the map —
    /// the editor's overlay, and the portrait and door prompt the world itself raises.
    ///
    /// Layered rather than taken in one shot because `cacheDisplay` renders every AppKit view
    /// but leaves the Metal view blank, so anything above the map has to land *after* the
    /// world image that would otherwise paint over it.
    static func write(world: CGImage, map: NSView, overlays: [NSView], to path: String) -> Bool {
        guard let content = map.window?.contentView else { return false }

        let scale = map.window?.backingScaleFactor ?? 2
        let pixelWidth = Int(content.bounds.width * scale)
        let pixelHeight = Int(content.bounds.height * scale)

        guard let ctx = CGContext(data: nil,
                                  width: pixelWidth,
                                  height: pixelHeight,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        ctx.scaleBy(x: scale, y: scale)

        if let image = snapshot(of: content) {
            ctx.draw(image, in: content.bounds)
        }

        // The map view's rectangle in the content view's (Y-up) coordinate space.
        ctx.draw(world, in: map.convert(map.bounds, to: content))
        for layer in overlays where !layer.isHidden {
            guard let image = snapshot(of: layer) else { continue }
            ctx.draw(image, in: layer.convert(layer.bounds, to: content))
        }

        guard let composed = ctx.makeImage() else { return false }
        let bitmap = NSBitmapImageRep(cgImage: composed)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    private static func snapshot(of view: NSView) -> CGImage? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }
}
