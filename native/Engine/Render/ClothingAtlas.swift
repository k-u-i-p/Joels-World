import Metal
import simd

/// Which strip of the clothing atlas a vertex reads.
///
/// One row of the texture each, in this order, top to bottom. `blank` is first so that the
/// default — a vertex nobody thought about — comes out as bare palette colour rather than as a
/// collar wrapped round somebody's hand.
enum ClothingRegion: Int, CaseIterable {
    /// Skin: the neck and the hands. Neutral everywhere, so these render exactly as they did
    /// before there was a texture at all.
    case blank = 0
    case torso
    case pelvis
    case arm
    case leg
}

/// **The clothes, painted rather than modelled.**
///
/// The body is one skinned mesh and its colour comes from a four-entry palette — skin, shirt,
/// arm, pants — so every character is four flat fields of colour with nothing on them. A collar,
/// a button placket, a turn-up on a sleeve and a school sock are what the reference render has
/// and this does not, and all four are *surface* detail: there is no geometry to add, only
/// something to say about each point of the surface that is already there.
///
/// So this is a texture. Not an albedo, though — an albedo would have to be repainted for every
/// character, because the shirt colour is per-character data and there are dozens of them. It is
/// a **control map**, three channels of instruction that the shader applies *to* whatever colour
/// the palette handed that vertex:
///
/// | channel | what it says |
/// |---|---|
/// | red   | **shade** — multiply by `2 × r`, so 0.5 is "leave it alone". Seams, folds, the shadow a sleeve casts. |
/// | green | **trim** — mix towards `trimColor`. Collars and socks. |
/// | blue  | **bare** — mix towards the character's own skin colour. Below a short sleeve, between the shorts and the sock. |
///
/// One texture serves every character in the game, in the one draw call the body already costs.
///
/// **The blue channel is the one that changes how everyone looks.** Before it, an arm was shirt
/// colour from the shoulder to the wrist and a leg was shorts colour from the hip to the shoe,
/// because that is all a per-part colour can say. `sleeveEnd`, `shortsEnd` and `sockTop` below
/// are where that is decided; set `sleeveEnd` to 1 and everybody is back in long sleeves.
///
/// Nothing here was drawn by hand either. Every mark is a band or a bump in `(u, v)`, and `u`
/// and `v` mean something anatomical — see `uv(_:u:v:)`.
enum ClothingAtlas {

    // MARK: - Layout

    /// Texels around the body. The torso is about 65 units round, so this is roughly 4 texels
    /// per unit — the same ballpark as the vertical resolution, which keeps a stitch line the
    /// same width whichever way it runs.
    static let width = 256
    /// Texels along each region.
    static let rowHeight = 64
    /// Rows at the top and bottom of each region that no `v` maps into.
    ///
    /// The sampler is bilinear and the regions are stacked touching, so without a margin the
    /// collar at the top of the torso would bleed into the waistband at the top of the shorts.
    /// The painter clamps `v`, so the guard rows come out as a copy of the edge they guard.
    static let guardRows = 2

    static var height: Int { rowHeight * ClothingRegion.allCases.count }

    /// Collars, cuffs and socks. Deliberately not pure white — a white that bright next to a
    /// lit shirt reads as a hole in the character rather than as cotton.
    static let trimColor = SIMD3<Float>(0.90, 0.91, 0.88)

    // MARK: - Where the clothes sit
    //
    // All in the `v` of the region named, which is spelled out at each painter below. These are
    // the numbers to move; everything else is detail hung off them.

    /// How far down the arm the sleeve stops. 0.42 is a little over half the upper arm.
    static let sleeveEnd: Float = 0.42
    /// How far down the leg the shorts stop. The shorts *mesh* stops at about 0.30, so this is
    /// where the leg stops being trouser-coloured and starts being a knee.
    static let shortsEnd: Float = 0.30
    /// Where the sock starts, a little below the knee (which is at about 0.57).
    static let sockTop: Float = 0.70

    /// Turns a region-local `(u, v)` into a texture coordinate.
    ///
    /// **`u` = 0 is the front of the surface, 1 is the back, and it is the same going round
    /// either way.** The body is mirrored down the middle, so half a wrap is all there is to
    /// paint — and folding it is not only economy, it is the thing that makes the seam work.
    ///
    /// A surface revolved all the way round has to come back to where it started, and a UV that
    /// runs 0…1 round it does not: the last quad has u going from 0.96 back to 0, and it renders
    /// the whole texture row squeezed into one strip down the character's back. Fold `u` about
    /// the front instead — the two sides of the body reaching 1 at the spine from opposite
    /// directions — and there is no jump anywhere, because the parameter turns round rather than
    /// wrapping. `SkinnedBody.facing` does that for the torso and the shorts, from the bind-space
    /// position rather than the lathe's own angle, so 0 really is the middle of the chest whatever
    /// `MeshFactory` and the bind rotation do between them. A limb folds its ring index the same
    /// way. The price is that nothing here can be left-right asymmetric: a badge on one pocket
    /// would come out on both.
    ///
    /// `v` runs **along** the surface, 0 to 1, and what the two ends are is written down at each
    /// painter.
    static func uv(_ region: ClothingRegion, u: Float, v: Float) -> SIMD2<Float> {
        let span = Float(rowHeight - 2 * guardRows - 1)
        let row = Float(region.rawValue * rowHeight)
        // Land on texel centres: v = 0 is the centre of the first row inside the guard.
        let y = row + Float(guardRows) + 0.5 + min(max(v, 0), 1) * span
        return SIMD2(u, y / Float(height))
    }

    // MARK: - Painting

    /// What one texel says. The defaults are "change nothing", which is what the blank region is
    /// and what every painter starts from.
    private struct Detail {
        var shade: Float = 0.5
        var trim: Float = 0
        var bare: Float = 0
    }

    static func make(device: MTLDevice) -> MTLTexture? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let span = Float(rowHeight - 2 * guardRows - 1)

        for region in ClothingRegion.allCases {
            for row in 0..<rowHeight {
                // The inverse of `uv`. Rows inside the guard clamp to 0 or 1, so the margin is a
                // copy of the edge and a bilinear tap that strays into it finds the same thing.
                let v = min(max((Float(row - guardRows)) / span, 0), 1)
                for column in 0..<width {
                    let u = (Float(column) + 0.5) / Float(width)
                    let detail = paint(region, u: u, v: v)
                    let index = ((region.rawValue * rowHeight + row) * width + column) * 4
                    pixels[index] = byte(detail.shade)
                    pixels[index + 1] = byte(detail.trim)
                    pixels[index + 2] = byte(detail.bare)
                    pixels[index + 3] = 255
                }
            }
        }

        // **Not** sRGB, and not loaded through `MTKTextureLoader`. These are three instructions
        // and an unused alpha, not a colour: a gamma curve applied to "multiply by 1" would
        // quietly stop meaning 1.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                  width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                        mipmapLevel: 0, withBytes: pixels, bytesPerRow: width * 4)
        return texture
    }

    private static func paint(_ region: ClothingRegion, u: Float, v: Float) -> Detail {
        switch region {
        case .blank: return Detail()
        case .torso: return shirt(u: u, v: v)
        case .pelvis: return shorts(u: u, v: v)
        case .arm: return sleeve(u: u, v: v)
        case .leg: return legwear(u: u, v: v)
        }
    }

    /// **The shirt.** `v` = 0 at the hem, 1 at the neck root, over the twenty units of
    /// `CharacterRig.torsoProfile`. The waist is at 0.20, the chest at 0.65, the shoulder yoke at
    /// 0.83. `u` = 0 is dead centre of the chest and 0.5 is the side seam.
    ///
    /// The horizontal scale near the front works out at about 0.053 of `u` per unit of chest, so
    /// a placket 2.5 units wide is 0.065 either side of nothing.
    private static func shirt(u: Float, v: Float) -> Detail {
        var detail = Detail()

        // The collar, with a V at the front. `dip` is 1 on the centre line and 0 by a fifth of
        // the way round, and squaring it makes the V pointed rather than round-bottomed.
        let dip = max(0, 1 - u / 0.21)
        let collarBottom = 0.865 - 0.095 * dip * dip
        detail.trim = rise(v, at: collarBottom, over: 0.018)

        // The button placket: a strip of doubled cloth down the centre, a seam either side of it
        // and four buttons on it. It stops where the collar starts.
        let along = between(v, 0.10, collarBottom - 0.015, soft: 0.02)
        let strip = 1 - rise(u, at: 0.065, over: 0.012)
        detail.shade += 0.045 * strip * along
        detail.shade -= 0.13 * line(u, at: 0.072, halfWidth: 0.010) * along
        for button in [Float(0.28), 0.44, 0.60, 0.76] {
            detail.shade -= 0.22 * blob(u: u, v: v, atU: 0, atV: button, radiusU: 0.040, radiusV: 0.037)
        }

        // The shirt is loose over the shorts, so the last inch of it is in its own shadow.
        detail.shade -= 0.11 * (1 - rise(v, at: 0.085, over: 0.055))
        // The yoke seam across the shoulders.
        detail.shade -= 0.055 * line(v, at: 0.815, halfWidth: 0.006)
        return detail
    }

    /// **The shorts.** `v` = 0 where the thighs leave, 1 at the top, under the shirt hem — the
    /// eleven units of `CharacterRig.pelvisProfile`. Only the bottom half is ever visible; the
    /// rest is inside the shirt.
    private static func shorts(u: Float, v: Float) -> Detail {
        var detail = Detail()
        // The turn-up at the bottom of the leg, and the stitch line holding it.
        detail.shade -= 0.11 * between(v, 0.03, 0.13, soft: 0.015)
        detail.shade -= 0.10 * line(v, at: 0.15, halfWidth: 0.008)
        // The side seam, at the hip — u = 0.5 is a quarter turn from the front, and the fold
        // means the one line is drawn on both hips.
        detail.shade -= 0.11 * line(u, at: 0.5, halfWidth: 0.014)
        // The fly, front centre and only as far up as the shirt.
        detail.shade -= 0.09 * line(u, at: 0, halfWidth: 0.045) * between(v, 0.05, 0.44, soft: 0.05)
        return detail
    }

    /// **The sleeve, and the arm out of it.** `v` = 0 at the top of the deltoid, buried in the
    /// chest, and 1 at the end of the wrist cap — roughly twenty-one units of swept arm, of which
    /// the upper arm is the first three fifths.
    private static func sleeve(u: Float, v: Float) -> Detail {
        var detail = Detail()
        detail.bare = rise(v, at: sleeveEnd, over: 0.012)
        // The turn-up hem, just above the edge.
        detail.shade -= 0.13 * between(v, sleeveEnd - 0.055, sleeveEnd - 0.004, soft: 0.008)
        // The shadow the sleeve drops on the arm below it, fading out over an inch of skin.
        detail.shade -= 0.15 * detail.bare * (1 - rise(v, at: sleeveEnd, over: 0.075))
        // Where the sleeve is set into the yoke.
        detail.shade -= 0.06 * line(v, at: 0.115, halfWidth: 0.010)
        return detail
    }

    /// **The leg: shorts, knee, sock.** `v` = 0 at the top of the hip cap, inside the shorts, and
    /// 1 at the end of the ankle cap, inside the shoe. The knee is at about 0.57.
    private static func legwear(u: Float, v: Float) -> Detail {
        var detail = Detail()
        detail.bare = rise(v, at: shortsEnd, over: 0.018)
        detail.trim = rise(v, at: sockTop, over: 0.015)
        // The hem of the shorts, and its shadow on the thigh.
        detail.shade -= 0.11 * between(v, shortsEnd - 0.06, shortsEnd - 0.005, soft: 0.010)
        detail.shade -= 0.13 * detail.bare * (1 - rise(v, at: shortsEnd, over: 0.06))
        // The roll at the top of the sock — the fold, then the ribbing under it.
        detail.shade -= 0.09 * line(v, at: sockTop + 0.030, halfWidth: 0.016)
        detail.shade -= 0.05 * between(v, sockTop + 0.05, sockTop + 0.12, soft: 0.02)
        return detail
    }

    // MARK: - Marks
    //
    // Four shapes, all soft-edged, all in `(u, v)`. Hard edges alias badly on a surface this
    // small on screen — a one-texel stitch line with a step edge crawls as the character walks.

    /// 0 below `edge`, 1 above it, smooth across `over`.
    private static func rise(_ x: Float, at edge: Float, over: Float) -> Float {
        smoothstep((x - edge) / max(over, 1e-5) + 0.5)
    }

    /// 1 between `lo` and `hi`, fading out over `soft` at each end.
    private static func between(_ x: Float, _ lo: Float, _ hi: Float, soft: Float) -> Float {
        rise(x, at: lo, over: soft) * (1 - rise(x, at: hi, over: soft))
    }

    /// A soft line centred on `at`. Peaks at 1.
    private static func line(_ x: Float, at centre: Float, halfWidth: Float) -> Float {
        let t = min(abs(x - centre) / max(halfWidth, 1e-5), 1)
        return 1 - smoothstep(t)
    }

    /// A soft ellipse. Nothing wraps here — `u` is folded, so 0 and 1 are the front and the back
    /// rather than two names for the same place, and a plain distance is the right one.
    private static func blob(u: Float, v: Float,
                             atU: Float, atV: Float,
                             radiusU: Float, radiusV: Float) -> Float {
        let du = (u - atU) / radiusU
        let dv = (v - atV) / radiusV
        return 1 - smoothstep(min((du * du + dv * dv).squareRoot(), 1))
    }

    private static func smoothstep(_ x: Float) -> Float {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }

    private static func byte(_ value: Float) -> UInt8 {
        UInt8(min(max(value, 0), 1) * 255 + 0.5)
    }
}
