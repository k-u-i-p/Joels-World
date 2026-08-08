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
/// | red   | **shade** — multiply by `2 × r`, so 0.5 is "leave it alone". Seams, folds, and the shadow one part of the body throws on another. |
/// | green | **trim** — mix towards `trimColor`. Collars and socks. |
/// | blue  | **bare** — mix towards the character's own skin colour. Below a short sleeve, between the shorts and the sock. |
///
/// One texture serves every character in the game, in the one draw call the body already costs.
///
/// **Half of what the red channel does is stand in for light that is not there.** The scene has
/// one spotlight and a flat ambient term, and without an environment map `shadeStandard`
/// contributes no indirect light at all — so a surface facing away from the spotlight is lit
/// exactly as brightly whether it is out in the open or wedged under an arm. Nothing in the
/// renderer knows that the deltoid is buried in the chest or that the shirt hangs over the
/// shorts, and a body with no shadow anywhere it folds reads as a painted cylinder however good
/// the silhouette underneath is. The armpit wedge in `shirt`, the hem shadow in `shorts` and the
/// contact shadows under the sleeve and the shorts hem are all that occlusion, painted by hand
/// because there is nowhere else for it to come from.
///
/// The price is that it is *baked*: the shadow under an arm is there when the arm is raised. Each
/// of those marks is kept shallow enough to read as a crease in cloth when it is wrong, which is
/// the whole reason none of them is as dark as the real occlusion would be.
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

    /// Where the hem of the shirt crosses the shorts, in the *shorts'* `v`.
    ///
    /// Nothing in the geometry says this — the shirt and the shorts are two separate lathes and
    /// neither knows about the other — so it is worked out from where they sit. Both stand on the
    /// body pivot, the shirt's at `torsoCentreZ` 20 and the shorts' at `pelvisCentreZ` 11, and the
    /// shirt closes at its own y −6.4, which is rig z 13.6, with its last full ring at 14.0. Rig z
    /// 14.0 is the shorts' y 3.0, and their profile runs −6.2…5.0, so: (3.0 + 6.2) / 11.2 = 0.82.
    ///
    /// **Move this if either lathe moves.** Above it the shorts are inside the shirt and painted
    /// nearly black; below it they come out of a cast shadow. Both are wrong by the same amount if
    /// this is wrong, which at least makes the error easy to see.
    static let shirtHem: Float = 0.82

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
        let pixels = self.pixels()

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

    /// The atlas as raw RGBA bytes, no Metal involved.
    ///
    /// Split out from `make` so the thing can be *looked at*. Every mark here is a number in a
    /// band or a bump, and reading numbers is a poor way to find out that a button came out as a
    /// dash — `tools/clothing_atlas.swift` compiles this file on its own and writes the result to
    /// a PNG, which takes a second and answers the question directly.
    static func pixels() -> [UInt8] {
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
        return pixels
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
        //
        // 0.775 rather than the neck root at 0.98, and the V down to 0.63, because of what the
        // *silhouette* does up there: from 0.83 upwards the profile is the trapezius sloping in
        // to the neck, which faces almost straight up and is hidden by the head from every camera
        // this game has. A collar painted where a collar sits is a collar nobody sees. This one
        // sits on the shoulders and opens onto the chest, which is where it reads.
        let dip = max(0, 1 - u / 0.21)
        let collarBottom = 0.775 - 0.145 * dip * dip
        detail.trim = rise(v, at: collarBottom, over: 0.018)

        // **The shadow under the collar**, which is what makes it a collar rather than a white
        // area. Almost all of the trim above faces up and away, so from a camera looking down at
        // a character it is edge-on and only a few pixels of it survive; the eye finds a garment
        // edge far more reliably by the dark line beneath it than by the light band itself. This
        // is that line, and it is drawn on shirt-coloured cloth where it stays visible.
        detail.shade -= 0.15 * between(v, collarBottom - 0.095, collarBottom - 0.004, soft: 0.030)

        // The button placket: a strip of doubled cloth down the centre, a seam either side of it
        // and four buttons on it. It stops where the collar starts.
        //
        // Wider and darker than a real one, because of how few pixels it gets. The front face of
        // the chest is about eleven units across and a character in the overworld is forty pixels
        // tall: a placket at true scale is one pixel, which is not a placket, it is a stray. At
        // this width it reads at overworld range and still looks like cloth up close.
        let along = between(v, 0.10, collarBottom - 0.015, soft: 0.02)
        let strip = 1 - rise(u, at: 0.075, over: 0.014)
        detail.shade += 0.05 * strip * along
        detail.shade -= 0.16 * line(u, at: 0.084, halfWidth: 0.012) * along
        for button in [Float(0.28), 0.42, 0.56, 0.70] {
            detail.shade -= 0.28 * blob(u: u, v: v, atU: 0, atV: button, radiusU: 0.046, radiusV: 0.040)
        }

        // The shirt is loose over the shorts, so the crease at the hem is in its own shadow.
        // Gently — at this size a strong band across the waist stops reading as a shadow and
        // starts reading as a belt. It is the top half of the pair the shorts finish: this is
        // the underside of the hem going dark, `shorts` is the shadow it throws.
        detail.shade -= 0.12 * (1 - rise(v, at: 0.085, over: 0.080))
        // The yoke seam across the shoulders.
        detail.shade -= 0.055 * line(v, at: 0.815, halfWidth: 0.006)

        // **Under the arm.** `limbRings` domes the top of an arm back *past* the shoulder joint
        // on purpose, so the deltoid is buried in this surface and the ribs beside it are in a
        // pocket the spotlight never reaches. There is no indirect light in this scene — three.js
        // contributes none without an environment map and neither does `shadeStandard` — so that
        // pocket was coming out exactly as bright as the middle of the chest, and a body with no
        // shadow where its arm meets it reads as a painted cylinder however good the silhouette
        // underneath is. This is the single darkest mark in the atlas for that reason.
        //
        // The shoulder joint sits at rig z 26, which is v 0.62, and the deltoid is 3.75 across;
        // the wedge is centred just below it. `u` 0.5 is the side seam, and the fold means the
        // one mark is drawn under both arms.
        let flank = line(u, at: 0.5, halfWidth: 0.34)
        detail.shade -= 0.22 * flank * between(v, 0.38, 0.70, soft: 0.14)
        // Fainter, further down: where a hanging arm lies against the ribs. It is wrong the
        // moment the arm lifts, which is what a baked shadow costs — kept shallow for that
        // reason, and at this depth a raised arm reads as the shirt creasing rather than as a
        // shadow with nothing casting it.
        detail.shade -= 0.08 * flank * between(v, 0.06, 0.42, soft: 0.16)

        // Drape. A school shirt on a ten-year-old is not shrink-wrapped to him — it hangs off the
        // chest and gathers into soft vertical creases on the way to the hem. Two of them, wide
        // and shallow: `u` is folded, so each is drawn on both sides of the body, which is what a
        // garment hanging off two shoulders does anyway.
        let hangs = between(v, 0.04, 0.60, soft: 0.22)
        detail.shade -= 0.045 * line(u, at: 0.33, halfWidth: 0.11) * hangs
        detail.shade -= 0.035 * line(u, at: 0.68, halfWidth: 0.10) * hangs
        return detail
    }

    /// **The shorts.** `v` = 0 where the thighs leave, 1 at the top, under the shirt hem — the
    /// eleven units of `CharacterRig.pelvisProfile`. Only the bottom half is ever visible; the
    /// rest is inside the shirt.
    private static func shorts(u: Float, v: Float) -> Detail {
        var detail = Detail()

        // **The shirt's shadow, and the reason the shorts read as shorts.**
        //
        // Shirt and shorts are two per-character colours in `npc.json` and a great many
        // characters have them near enough the same — the Admin's are both the same teal — so
        // from the side there was one unbroken field of colour from the collar to the knee and
        // nothing anywhere saying which part of it was a garment. Colour cannot fix that, because
        // the colours are Joel's to choose. Light can: a shirt hanging over a pair of shorts
        // throws a shadow on them, and a shadow is the same shadow whatever colour it falls on.
        //
        // Two marks. The cast shadow, deepest where the hem crosses and easing out over about
        // three units of shorts below it; then everything above the hem, which is *inside* the
        // shirt and should be nearly black.
        detail.shade -= 0.30 * rise(v, at: shirtHem - 0.17, over: 0.30)
        detail.shade -= 0.13 * rise(v, at: shirtHem - 0.01, over: 0.05)

        // The turn-up at the bottom of the leg, and the stitch line holding it.
        detail.shade -= 0.11 * between(v, 0.03, 0.13, soft: 0.015)
        detail.shade -= 0.10 * line(v, at: 0.15, halfWidth: 0.008)
        // The side seam, at the hip — u = 0.5 is a quarter turn from the front, and the fold
        // means the one line is drawn on both hips.
        detail.shade -= 0.11 * line(u, at: 0.5, halfWidth: 0.014)
        // The fly, front centre and only as far up as the shirt.
        detail.shade -= 0.09 * line(u, at: 0, halfWidth: 0.045) * between(v, 0.05, 0.44, soft: 0.05)
        // The same drape the shirt has, on the part of the shorts that hangs free of the hip.
        detail.shade -= 0.045 * line(u, at: 0.27, halfWidth: 0.10) * between(v, 0.02, 0.38, soft: 0.14)
        return detail
    }

    /// **The sleeve, and the arm out of it.** `v` = 0 at the top of the deltoid, buried in the
    /// chest, and 1 at the end of the wrist cap — roughly twenty-one units of swept arm, of which
    /// the upper arm is the first three fifths.
    private static func sleeve(u: Float, v: Float) -> Detail {
        var detail = Detail()
        detail.bare = rise(v, at: sleeveEnd, over: 0.012)
        // The turn-up hem, just above the edge.
        detail.shade -= 0.16 * between(v, sleeveEnd - 0.060, sleeveEnd - 0.004, soft: 0.008)
        // The shadow the sleeve drops on the arm below it, fading out over an inch of skin.
        detail.shade -= 0.17 * detail.bare * (1 - rise(v, at: sleeveEnd, over: 0.090))
        // Where the sleeve is set into the yoke.
        detail.shade -= 0.06 * line(v, at: 0.115, halfWidth: 0.010)

        // The elbow, at three fifths along. Nothing here can tell the inside of an arm from the
        // outside — `u` on a limb is the ring index, and the ring frame is parallel-transported
        // rather than anatomical (`SkinnedBody.appendTube`) — so this is a ring right round,
        // which is a crease all the way round rather than a fold on the inside. Kept faint
        // enough to be that: it reads as the arm narrowing at the joint, which it does.
        detail.shade -= 0.045 * line(v, at: 0.60, halfWidth: 0.055)

        // The wrist. The hand is a separate mesh butted onto the end of this tube and deliberately
        // not blended across the join (see `SkinnedBody.appendBody` — a blend there screws the
        // wrist shut), so the seam is a hard edge between two flat fields of the same colour. A
        // little shade in the last of the arm turns it into a wrist rather than into the joint of
        // a doll.
        detail.shade -= 0.12 * rise(v, at: 0.90, over: 0.10)
        return detail
    }

    /// **The leg: shorts, knee, sock.** `v` = 0 at the top of the hip cap, inside the shorts, and
    /// 1 at the end of the ankle cap, inside the shoe. The knee is at about 0.57.
    private static func legwear(u: Float, v: Float) -> Detail {
        var detail = Detail()
        detail.bare = rise(v, at: shortsEnd, over: 0.018)
        detail.trim = rise(v, at: sockTop, over: 0.015)
        // The hem of the shorts, and its shadow on the thigh. The shadow runs further down the
        // leg than the sleeve's does on the arm, because the shorts hang further off what is
        // under them than a sleeve does — a bare thigh straight out of a bright hem is the tell
        // that the two are painted on one surface rather than one hanging over the other.
        detail.shade -= 0.11 * between(v, shortsEnd - 0.06, shortsEnd - 0.005, soft: 0.010)
        detail.shade -= 0.20 * detail.bare * (1 - rise(v, at: shortsEnd, over: 0.14))
        // The roll at the top of the sock — the fold, then the ribbing under it.
        detail.shade -= 0.09 * line(v, at: sockTop + 0.030, halfWidth: 0.016)
        detail.shade -= 0.05 * between(v, sockTop + 0.05, sockTop + 0.12, soft: 0.02)
        // The ankle, which the shoe swallows. Free where it does; where a stride pulls a gap open
        // between the two it is a shadow inside a shoe rather than a bright white stub.
        detail.shade -= 0.12 * rise(v, at: 0.94, over: 0.06)
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
