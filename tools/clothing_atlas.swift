// Writes the character clothing atlas to a PNG so it can be looked at.
//
//   swiftc -O -parse-as-library tools/clothing_atlas.swift \
//           native/Engine/Render/ClothingAtlas.swift -o /tmp/atlas
//   /tmp/atlas /tmp/atlas.png
//
// The atlas is a control map, not a picture — red is a shade multiplier, green is trim coverage,
// blue is bare skin — so the PNG reads as a lurid false-colour thing rather than as clothes. That
// is the point: a button that has come out as a dash, or a collar that has slid into the guard
// rows, is obvious here and very hard to see on a character forty pixels tall.
//
// It compiles `ClothingAtlas.swift` itself rather than a copy, so what it draws is what the game
// uploads.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
struct ClothingAtlasDump {
    static func main() {
        let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/clothing_atlas.png"

        let pixels = ClothingAtlas.pixels()
        let width = ClothingAtlas.width
        let height = ClothingAtlas.height

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height,
                                  bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL,
                                                                UTType.png.identifier as CFString, 1, nil)
        else {
            FileHandle.standardError.write(Data("could not build the image\n".utf8))
            exit(1)
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            FileHandle.standardError.write(Data("could not write \(output)\n".utf8))
            exit(1)
        }

        print("\(width)×\(height) → \(output)")
        for region in ClothingRegion.allCases {
            print("  row \(region.rawValue): \(region)  y \(region.rawValue * ClothingAtlas.rowHeight)…\((region.rawValue + 1) * ClothingAtlas.rowHeight - 1)")
        }

    }
}
