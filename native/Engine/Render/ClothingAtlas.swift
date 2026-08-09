import Metal
import simd

/// Which strip of the clothing atlas a vertex reads.
///
/// One row of the texture each, in this order, top to bottom. `blank` is first so that the
/// default — a vertex nobody thought about — comes out as bare palette colour rather than as a
/// collar wrapped round somebody's hand.
enum ClothingRegion: Int, CaseIterable {
    /// Neutral everywhere — bare palette colour. What a vertex nobody thought about gets.
    case blank = 0
    case torso
    case pelvis
    case arm
    case leg
    /// Bare skin, both of them. They were `blank` for three sessions: skin has no garment on it,
    /// so there was nothing for a *clothing* atlas to say. What they do have is **shape** that
    /// the one spotlight cannot show — a hand's knuckles and the cup of its palm, and a neck
    /// buried under the overhang of a very large head — and the red channel has been standing in
    /// for absent light since session 3. That is the same job.
    case hand
    case neck
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
    /// body pivot, the shirt's at `torsoCentreZ` 20 and the shorts' at `pelvisCentreZ` 11.
    ///
    /// It is where the two **surfaces cross**, which is not where either of them ends. The shirt
    /// climbs 7.2 → 7.9 wide between rig z 11.6 and 12.4 while the shorts fall from 8.3 to 7.3
    /// over the same run; they pass each other at about 7.4 each, at **rig z 12.2** — and within
    /// a twentieth of a unit of the same height front-to-back, which is what makes one number
    /// able to describe the crossing at all. That is the shorts' own y 1.2 on a profile running
    /// −6.2…4.0, so: (1.2 + 6.2) / 10.2 = 0.726.
    ///
    /// **0.726, down from 0.873** — the shirt's hem was taken lower and its closing dome removed
    /// so that the two surfaces cross once, steeply. See `CharacterRig.torsoProfile`.
    ///
    /// **Move this if either lathe moves.** Above it the shorts are inside the shirt; below it
    /// they come out of a cast shadow. Both are wrong by the same amount if this is wrong, which
    /// at least makes the error easy to see.
    static let shirtHem: Float = 0.726

    // MARK: - The shirt's heights
    //
    // `shirt` writes every one of its marks as a height in the **rig's own frame** — z up, zero
    // at the body pivot, the frame `CharacterRig` is written in — rather than as a fraction of
    // the shirt. Session 4 ended with a ⚠️ saying that moving either end of `torsoProfile` moves
    // every `v` on the garment and all of them have to be rescaled by hand; this is that warning
    // dealt with rather than repeated. Move the profile, change the two numbers below, and every
    // mark stays on the seam it was drawn on.
    //
    // They are **plain numbers rather than a read of `CharacterRig`** for one reason:
    // `tools/clothing_atlas.swift` compiles this file on its own, so it cannot see the engine.
    // Keep them equal to `torsoCentreZ` plus the first and last `y` of `torsoProfile`.

    /// Rig z of the shirt's open bottom rim — `torsoCentreZ` 20 + the profile's first y, −8.4.
    static let shirtFloorZ: Float = 11.6
    /// Rig z of the shirt's closed top — 20 + the profile's last y, 13.6.
    static let shirtCeilingZ: Float = 33.6

    /// A height on the character, as the shirt's `v`.
    static func shirtV(_ rigZ: Float) -> Float {
        (rigZ - shirtFloorZ) / (shirtCeilingZ - shirtFloorZ)
    }

    /// A distance up the character, as a span of the shirt's `v`. For the width of a band or the
    /// softness of an edge, where an absolute height would be meaningless.
    static func shirtSpan(_ units: Float) -> Float {
        units / (shirtCeilingZ - shirtFloorZ)
    }

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
        case .hand: return skinOfHand(u: u, v: v)
        case .neck: return skinOfNeck(u: u, v: v)
        }
    }

    /// **The hand.** `v` = 0 at the wrist ring buried in the forearm and 1 at `fingerReach`, over
    /// the nine and a half units the palm and the fingers span between them — so the wrist plane
    /// is at 0.23 and the knuckles at 0.54. `u` folds about the **back**: 0 down the middle of
    /// the back of the hand, 0.5 at either edge, 1 down the middle of the palm, and every finger
    /// folds the same way about its own centre line. `CharacterRenderer.buildHand` writes those
    /// UVs itself, because a ring's angle is known where the ring is made and nowhere afterwards.
    ///
    /// The fingers are modelled, so nothing here draws one. What it draws is what a single
    /// spotlight and a flat ambient cannot: a palm is a cup, and it reads as one only if it is
    /// darker than the back of the hand.
    private static func skinOfHand(u: Float, v: Float) -> Detail {
        var detail = Detail()

        // The hand's cast shadow on itself, back to palm. Real, and worth about this much: the
        // back of a hand faces the sky and the palm faces the ground, whichever way the arm is
        // turned, so unlike the armpit wedge this one is not wrong when the pose changes. It runs
        // out onto the undersides of the fingers, which is where it should go.
        detail.shade -= 0.11 * rise(u, at: 0.60, over: 0.42)
        // The cup of the palm, deepest just under the fingers where a hand hollows.
        detail.shade -= 0.07 * rise(u, at: 0.78, over: 0.28) * between(v, 0.26, 0.52, soft: 0.11)

        // The knuckles, on the back only: four soft rises, which the fold draws as two. The
        // fingers are separate solids and the palm domes over shut beneath them, so the joint
        // itself is smooth; this is the bone under it. Measured off the geometry — the middle
        // pair sit at z ±0.57 over a back 1.42 deep, which is u 0.12, and the outer pair at
        // ±1.70, which is 0.28.
        for knuckle in [Float(0.12), 0.28] {
            detail.shade += 0.05 * blob(u: u, v: v, atU: knuckle, atV: 0.545,
                                        radiusU: 0.07, radiusV: 0.05)
        }
        // The two creases across the underside of the fingers. A ring at a fixed `v` crosses all
        // four at once, which is near enough true of a hand with its fingers together.
        let underside = rise(u, at: 0.56, over: 0.22)
        detail.shade -= 0.07 * line(v, at: 0.685, halfWidth: 0.022) * underside
        detail.shade -= 0.05 * line(v, at: 0.830, halfWidth: 0.018) * underside

        // The wrist. The forearm butts onto this and is deliberately not blended across the join
        // (`SkinnedBody.appendBody` — a blend there screws the wrist shut), so without a mark the
        // seam is a hard edge between two flat fields of one colour. `sleeve` shades the arm's
        // last tenth for the same reason; this is the other half of that pair.
        detail.shade -= 0.10 * (1 - rise(v, at: 0.21, over: 0.10))
        // Where the thumb leaves the palm. It reaches both edges, the fold being what it is, and
        // the far edge is the heel of the hand, which is in a fold of its own.
        detail.shade -= 0.06 * line(u, at: 0.5, halfWidth: 0.18) * between(v, 0.25, 0.42, soft: 0.09)
        return detail
    }

    /// **The neck.** `v` = 0 where it leaves the shoulders and 1 where the head swallows it, over
    /// the seven units of `CharacterRig.neckLength`. `u` is unused — the neck is a plain cylinder
    /// and nothing about it is front-or-back at this size.
    ///
    /// These characters carry a big stylised head on a short neck (the collar's V is invisible
    /// for exactly that reason — see `shirt`), so the top of the neck lives permanently under an
    /// overhang and was coming out as bright as a cheek. This is the single mark that makes a
    /// head sit *on* a body rather than float above one.
    private static func skinOfNeck(u: Float, v: Float) -> Detail {
        var detail = Detail()
        detail.shade -= 0.26 * rise(v, at: 0.62, over: 0.55)
        // And a little at the bottom, inside the collar.
        detail.shade -= 0.08 * (1 - rise(v, at: 0.18, over: 0.16))
        return detail
    }

    /// **The shirt.** `v` = 0 at the closed bottom and 1 at the closed top, over the 21.2 units
    /// of `CharacterRig.torsoProfile` — but nothing below says `v` at all. Every mark is a rig
    /// height through `shirtV`, so the landmarks are the ones on the character: the hem edge at
    /// z 14.0, the waist at 17.9, the chest at 26.4, the shoulder at 28.4, the acromion at 30.0.
    ///
    /// `u` = 0 is dead centre of the chest, 0.5 the side seam, 1 down the spine.
    ///
    /// ⚠️ **`u` = 0 was the spine, not the chest, until this session** — see the note on
    /// `SkinnedBody.facing`. Everything front-facing here was landing on the back, which is worth
    /// knowing before believing any tuning note written before it: the collar's V was moved twice
    /// looking for a front it was never on.
    ///
    /// The horizontal scale near the front works out at about 0.05 of `u` per unit of chest, so
    /// a placket 2.5 units wide is 0.06 either side of nothing.
    private static func shirt(u: Float, v: Float) -> Detail {
        var detail = Detail()

        // The collar, with a V at the front. `dip` is 1 on the centre line and 0 by a quarter of
        // the way round, and squaring it makes the V pointed rather than round-bottomed.
        //
        // z 28.7 at the sides rather than the neck root at 33, because above about 31 the profile
        // is the trapezius sloping into the neck, which faces almost straight up and is hidden by
        // the head from every camera this game has. **The shoulders are the whole collar.**
        //
        // The front is still nearly decoration and for the reason session 3 gave, which survives
        // the `facing` fix: these characters carry a big stylised head on a short neck, and it
        // overhangs the chest so far that the highest shirt texel visible at the centre line is
        // around z 26. A V that dips to 25.6 puts a sliver of white under the chin and no more.
        // Going deeper to catch the overworld camera means painting white down the middle of the
        // chest, which stops being a collar and starts being a bib. If a front collar is ever
        // really wanted the fix is at the head — a longer neck or a smaller skull — not here.
        let dip = max(0, 1 - u / 0.24)
        let collarBottom = shirtV(28.7 - 3.1 * dip * dip)
        detail.trim = rise(v, at: collarBottom, over: shirtSpan(0.38))

        // **The shadow under the collar**, which is what makes it a collar rather than a white
        // area. Almost all of the trim above faces up and away, so from a camera looking down at
        // a character it is edge-on and only a few pixels of it survive; the eye finds a garment
        // edge far more reliably by the dark line beneath it than by the light band itself. This
        // is that line, and it is drawn on shirt-coloured cloth where it stays visible.
        detail.shade -= 0.15 * between(v, collarBottom - shirtSpan(1.9),
                                       collarBottom - shirtSpan(0.08), soft: shirtSpan(0.6))

        // The button placket: a strip of doubled cloth down the centre, a seam either side of it
        // and four buttons on it. It stops where the collar starts.
        //
        // Wider and darker than a real one, because of how few pixels it gets. The front face of
        // the chest is about eleven units across and a character in the overworld is forty pixels
        // tall: a placket at true scale is one pixel, which is not a placket, it is a stray. At
        // this width it reads at overworld range and still looks like cloth up close.
        let along = between(v, shirtV(15.6), collarBottom - shirtSpan(0.3), soft: shirtSpan(0.4))
        let strip = 1 - rise(u, at: 0.075, over: 0.014)
        detail.shade += 0.05 * strip * along
        detail.shade -= 0.16 * line(u, at: 0.084, halfWidth: 0.012) * along
        // Buttons are on the placket, so they are cut off by the same `along` the placket is —
        // without it the top one is painted onto the collar, which is a dark spot on a white
        // point rather than a button on a shirt.
        //
        // **Four of them, two units apart.** The comment has said four since session 3 and there
        // were three: the fourth ran off the top of the old placket. With the placket on the
        // chest rather than the spine they are worth counting, and the top one at z 24.4 is the
        // highest that clears the head's overhang.
        for button in [Float(18.4), 20.4, 22.4, 24.4] {
            detail.shade -= 0.28 * blob(u: u, v: v, atU: 0, atV: shirtV(button),
                                        radiusU: 0.046, radiusV: shirtSpan(0.8)) * along
        }

        // The shirt is loose over the shorts, so the crease at the hem is in its own shadow.
        // Gently — at this size a strong band across the waist stops reading as a shadow and
        // starts reading as a belt. It is the top half of the pair the shorts finish: this is
        // the underside of the hem going dark, `shorts` is the shadow it throws.
        detail.shade -= 0.12 * (1 - rise(v, at: shirtV(14.8), over: shirtSpan(1.6)))
        // **And then the last of it is lit again**, which is the same admission `shorts` makes
        // one garment down. The bottom two units of the shirt lean in under themselves, so the
        // spotlight rakes across them at nothing and there is no bounce in this scene to fill
        // them in; left alone they fall to flat ambient and read as a hole rather than as the
        // underside of a hem. This is that missing bounce, put back by hand.
        detail.shade += 0.09 * (1 - rise(v, at: shirtV(13.2), over: shirtSpan(1.4)))

        // The yoke seam across the shoulders, on the acromion.
        detail.shade -= 0.055 * line(v, at: shirtV(29.9), halfWidth: shirtSpan(0.12))

        // **Under the arm.** `limbRings` domes the top of an arm back *past* the shoulder joint
        // on purpose, so the deltoid is buried in this surface and the ribs beside it are in a
        // pocket the spotlight never reaches. There is no indirect light in this scene — three.js
        // contributes none without an environment map and neither does `shadeStandard` — so that
        // pocket was coming out exactly as bright as the middle of the chest, and a body with no
        // shadow where its arm meets it reads as a painted cylinder however good the silhouette
        // underneath is. This is the single darkest mark in the atlas for that reason.
        //
        // The shoulder joint sits at rig z 26 and the deltoid is 3.75 across; the wedge is
        // centred just below it. `u` 0.5 is the side seam, and the fold means the one mark is
        // drawn under both arms.
        let flank = line(u, at: 0.5, halfWidth: 0.34)
        detail.shade -= 0.22 * flank * between(v, shirtV(21.5), shirtV(27.0), soft: shirtSpan(2.6))
        // Fainter, further down: where a hanging arm lies against the ribs. It is wrong the
        // moment the arm lifts, which is what a baked shadow costs — kept shallow for that
        // reason, and at this depth a raised arm reads as the shirt creasing rather than as a
        // shadow with nothing casting it.
        detail.shade -= 0.08 * flank * between(v, shirtV(14.8), shirtV(22.0), soft: shirtSpan(3.2))

        // **The shoulder turning over.** The profile is 10.4 wide at z 28.4 and 8.6 by z 31.3, so
        // there is a real corner up there now — but it faces almost straight up, into the one
        // spotlight, and comes back as a flat bright field with the shoulder line invisible
        // inside it. This is the far side of that corner going into shade, which is the only
        // thing that says a shoulder has a top and a side.
        detail.shade -= 0.07 * flank * between(v, shirtV(28.6), shirtV(31.4), soft: shirtSpan(1.4))

        // **The back.** `u` near 1 is the spine, and the fold draws one mark on both sides of it —
        // which is exactly the symmetry a pair of shoulder blades has. The groove down the middle
        // and the two blades either side of it are the whole of what a back looks like, and this
        // surface had nothing on it at all.
        let acrossBack = between(v, shirtV(21.0), shirtV(30.5), soft: shirtSpan(2.4))
        detail.shade -= 0.055 * line(u, at: 1, halfWidth: 0.085) * acrossBack
        detail.shade += 0.035 * blob(u: u, v: v, atU: 0.80, atV: shirtV(27.6),
                                     radiusU: 0.115, radiusV: shirtSpan(2.6))
        detail.shade -= 0.045 * blob(u: u, v: v, atU: 0.80, atV: shirtV(24.4),
                                     radiusU: 0.115, radiusV: shirtSpan(2.2))

        // Drape. A school shirt on a ten-year-old is not shrink-wrapped to him — it hangs off the
        // chest and gathers into soft vertical creases on the way to the hem. Two of them, wide
        // and shallow: `u` is folded, so each is drawn on both sides of the body, which is what a
        // garment hanging off two shoulders does anyway.
        let hangs = between(v, shirtV(14.4), shirtV(25.6), soft: shirtSpan(4.4))
        detail.shade -= 0.045 * line(u, at: 0.33, halfWidth: 0.11) * hangs
        detail.shade -= 0.035 * line(u, at: 0.68, halfWidth: 0.10) * hangs

        detail.shade += cloth(u: u, v: v, seed: 1)
        return detail
    }

    /// **The shorts.** `v` = 0 where the thighs leave, 1 at the top, under the shirt hem — the
    /// **10.2** units of `CharacterRig.pelvisProfile`, which was 11.2 until the top of that
    /// profile was pulled in to stop it pushing through the shirt. Every `v` below was multiplied
    /// by 11.2/10.2 when it did, so each mark stayed on the same seam of the same garment. If
    /// that profile's floor or ceiling moves again, they all move again.
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
        // three units of shorts below it; then everything above the hem, which is inside the
        // shirt.
        //
        // **0.18 and 0.05, down from 0.30 and 0.13.** The two of them together took the shade to
        // 0.07 — a multiplier of 0.14 — on the top of the shorts, on the argument that nothing
        // could see it. Something can: the shirt hangs about a unit clear of the shorts and a
        // camera anywhere below the hem looks straight into the gap, where the spotlight is
        // already blocked and only the flat ambient reaches. Multiplying an ambient-lit surface
        // by 0.14 is how a shadow under a hem became a **black crescent across the belly** —
        // easily the loudest wrong thing on the character, and drawn there on purpose by a
        // number chosen for a surface that was assumed hidden. The shadow is real and stays; it
        // is now a shadow rather than a hole.
        detail.shade -= 0.18 * rise(v, at: shirtHem - 0.19, over: 0.33)
        detail.shade -= 0.05 * rise(v, at: shirtHem - 0.01, over: 0.055)
        // And then the pocket itself is **lit**, which is the opposite of everything else in this
        // file and is the honest thing to do. The gap under the hem gets no spotlight and no
        // bounce, because there is no bounce in this scene at all; a real one would fill it with
        // light off the shorts and the shirt lining, and without that it goes to flat ambient and
        // reads as a hole rather than as a shadow. This is that missing bounce, put back by hand
        // in the same band the shadow above occupies — a shadow with a floor to it instead of one
        // that runs to nothing.
        detail.shade += 0.09 * between(v, shirtHem - 0.22, shirtHem + 0.02, soft: 0.11)

        // The turn-up at the bottom of the leg, and the stitch line holding it.
        detail.shade -= 0.11 * between(v, 0.033, 0.143, soft: 0.016)
        detail.shade -= 0.10 * line(v, at: 0.165, halfWidth: 0.009)
        // The side seam, at the hip — u = 0.5 is a quarter turn from the front, and the fold
        // means the one line is drawn on both hips.
        detail.shade -= 0.11 * line(u, at: 0.5, halfWidth: 0.014)
        // The fly, front centre and only as far up as the shirt.
        detail.shade -= 0.09 * line(u, at: 0, halfWidth: 0.045) * between(v, 0.055, 0.483, soft: 0.055)
        // The same drape the shirt has, on the part of the shorts that hangs free of the hip.
        detail.shade -= 0.045 * line(u, at: 0.27, halfWidth: 0.10) * between(v, 0.022, 0.417, soft: 0.154)

        detail.shade += cloth(u: u, v: v, seed: 2)
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

    /// **Cloth.** A shallow, slow wobble in the shade, so a shirt is not one unbroken field of
    /// one colour.
    ///
    /// The characters read as plastic close up and it is not the silhouette's fault — it is that
    /// every texel of a shirt returns exactly the same number, which nothing woven has ever done.
    /// Two octaves of value noise on top of each other, worth about ±4% of brightness all told:
    /// far too little to see as a pattern, enough to see as a material.
    ///
    /// **The frequency is the part to be careful with.** The atlas has no mipmaps — it cannot
    /// have them, because the regions are stacked two guard rows apart and a mip would fold the
    /// collar into the waistband — so anything approaching one cycle per texel crawls as a
    /// character walks away from the camera. The coarse octave is about 26 texels across and the
    /// fine one 13, which at the width of a chest is a hand's breadth and half of one.
    ///
    /// Only the two cloth regions call it. Skin gets none: a forearm has no weave, and noise on
    /// bare skin at this amplitude reads as dirt.
    private static func cloth(u: Float, v: Float, seed: Int) -> Float {
        0.028 * valueNoise(u: u, v: v, cells: 10, seed: seed)
            + 0.014 * valueNoise(u: u, v: v, cells: 20, seed: seed + 64)
    }

    /// Smooth value noise on a `cells` × `cells` grid over the region, in −1…1.
    ///
    /// No wrap handling, and none needed: `u` is folded, so 0 and 1 are the chest and the spine
    /// rather than two names for the same place, and the two halves of the body meet at a mirror
    /// of the same values.
    private static func valueNoise(u: Float, v: Float, cells: Float, seed: Int) -> Float {
        let x = u * cells, y = v * cells
        let cellX = Int(x.rounded(.down)), cellY = Int(y.rounded(.down))
        let fx = smoothstep(x - Float(cellX)), fy = smoothstep(y - Float(cellY))
        let top = mix(corner(cellX, cellY, seed), corner(cellX + 1, cellY, seed), fx)
        let bottom = mix(corner(cellX, cellY + 1, seed), corner(cellX + 1, cellY + 1, seed), fx)
        return mix(top, bottom, fy)
    }

    /// One grid corner's value, in −1…1. An integer hash rather than a random number generator,
    /// so the atlas is the same texture on every machine and in every run — it is compiled into
    /// the game's look, and a shirt that mottles differently each launch is a bug.
    private static func corner(_ x: Int, _ y: Int, _ seed: Int) -> Float {
        var h = UInt32(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263 &+ seed &* 1_274_126_177)
        h ^= h >> 13
        h = h &* 1_274_126_177
        h ^= h >> 16
        return Float(h % 2048) / 1023.5 - 1
    }

    private static func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }

    private static func smoothstep(_ x: Float) -> Float {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }

    private static func byte(_ value: Float) -> UInt8 {
        UInt8(min(max(value, 0), 1) * 255 + 0.5)
    }
}
