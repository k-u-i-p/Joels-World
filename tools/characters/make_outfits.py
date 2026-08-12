#!/usr/bin/env python3
"""Make recoloured outfit textures for a bought character.

    python3 tools/characters/make_outfits.py --preview
    python3 tools/characters/make_outfits.py --write

A character in this game is one mesh with one base-colour texture: the shirt, the hair, the
shoes and the face are all painted into a single atlas, so there is no garment to swap and no
material to tint. This makes the swap possible the only way that stays honest — by producing a
**finished texture** with the garment already the colour we want, offline, where the result can
be looked at before it ships.

Why offline rather than in the engine: the engine tried it, and the atlases these models carry
are machine-packed — hundreds of small islands with skin, hair, shirt and shorts laid against
each other with no padding. Anything that asks "what colour is this vertex" lands on the
neighbouring island about a third of the time, and the result was bare shins painted as
trousers. There is no runtime tuning that fixes a UV layout.

What works instead is to do the whole thing **in texture space**, in two steps that each use the
signal they are actually good for:

1. **Which body part** each texel belongs to comes from the *bones*, by rasterising every
   triangle into the atlas. No colour is consulted, so the island layout cannot mislead it: a
   texel is head, torso, legs, feet or hand because a bone says so.
2. **Cloth or skin** then comes from the *colour*, compared against the character's own hands —
   and it is asked of whole areas rather than single points, so one bad texel is outvoted by the
   thousands around it.

The output is a mask that can be checked (`--preview`) and then a texture per outfit
(`--write`). Nothing in the engine has to guess about any of it.
"""

import argparse
import json
import os
import struct
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MODELS = os.path.join(ROOT, "assets", "models", "characters")
OUT_DIR = os.path.join(MODELS, "outfits")

# Region ids, matching the order the outfits below name them.
SKIN, HAIR, TOP, BOTTOMS, SHOES = range(5)
REGION_NAMES = ["skin", "hair", "top", "bottoms", "shoes"]
# What the preview paints each one, so a mistake is obvious rather than subtle.
PREVIEW = np.array([[0, 0, 0], [220, 30, 30], [40, 200, 60], [40, 90, 230], [220, 40, 220]],
                   dtype=np.uint8)

COMP = {5120: ("b", 1), 5121: ("B", 1), 5122: ("h", 2),
        5123: ("H", 2), 5125: ("I", 4), 5126: ("f", 4)}
NCOMP = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}

# --- What each model wears, and what else it could ---
#
# Keep these few. Every variant is a whole 2048² texture, and a corridor with eight differently
# dressed pupils in it is eight of them resident at once — see the note at the bottom of
# HANDOFF-imported-characters-part6.md.
OUTFITS = {
    "red":    {TOP: "#c0392b", BOTTOMS: "#2c3e50"},
    "blue":   {TOP: "#2e6fb7", BOTTOMS: "#34495e"},
    "green":  {TOP: "#27795a", BOTTOMS: "#3d3b32"},
    "yellow": {TOP: "#d9a520", BOTTOMS: "#4a4a52"},
    # **Hair colours are picked dark and warm, and there is no blond here.** Both facts are the
    # same limitation. A recolour moves hue and re-levels brightness, but it cannot invent what a
    # much lighter colour would look like: every model in this catalogue has dark hair, and asked
    # for blond they come back khaki — the right hue at a brightness the eye reads as dirt — with
    # the irises, which are hair-coloured and not caught by the eye test below, going with it.
    # Ginger stays close enough to home to work on all five. A real blond wants a blond model.
    "ginger": {HAIR: "#c2622a"},
}

MODEL_KEYS = ["son", "daughter", "father", "mother", "stylized_boy"]


# --------------------------------------------------------------------------- glTF

def load_glb(path):
    data = open(path, "rb").read()
    offset, js, binary = 12, None, None
    while offset < len(data):
        length, kind = struct.unpack_from("<II", data, offset)
        chunk = data[offset + 8:offset + 8 + length]
        if kind == 0x4E4F534A:
            js = json.loads(chunk)
        elif kind == 0x004E4942:
            binary = chunk
        offset += 8 + length
    return js, binary


def accessor(js, binary, index):
    a = js["accessors"][index]
    view = js["bufferViews"][a["bufferView"]]
    fmt, size = COMP[a["componentType"]]
    n = NCOMP[a["type"]]
    stride = view.get("byteStride") or size * n
    base = view.get("byteOffset", 0) + a.get("byteOffset", 0)
    if stride == size * n:
        raw = np.frombuffer(binary, dtype=np.dtype(fmt), count=a["count"] * n,
                            offset=base).astype(np.float64)
        return raw.reshape(a["count"], n)
    out = np.empty((a["count"], n), dtype=np.float64)
    for k in range(a["count"]):
        out[k] = struct.unpack_from("<" + fmt * n, binary, base + k * stride)
    return out


def base_colour_image(js, binary, primitive):
    material = js["materials"][primitive["material"]]
    ref = material["pbrMetallicRoughness"]["baseColorTexture"]["index"]
    source = js["textures"][ref]["source"]
    view = js["bufferViews"][js["images"][source]["bufferView"]]
    o = view.get("byteOffset", 0)
    return binary[o:o + view["byteLength"]]


# --------------------------------------------------------------------------- masks

def bone_groups(js):
    """Which body part each joint belongs to, walked down the node tree so that the thirty
    finger joints and the toe ends inherit the hand's and the foot's."""
    joints = js["skins"][0]["joints"]
    names = [js["nodes"][n].get("name", "") for n in joints]
    parent = {}
    for index, node in enumerate(js["nodes"]):
        for child in node.get("children", []):
            parent[child] = index
    to_joint = {n: i for i, n in enumerate(joints)}

    def own(name):
        low = name.lower().replace("mixamorig:", "").replace("_", "")
        if "toe" in low or "foot" in low:
            return "feet"
        if "hand" in low or "thumb" in low or "index" in low or "middle" in low \
                or "ring" in low or "pinky" in low:
            return "hand"
        if "head" in low:
            return "head"
        if "leg" in low or "hips" in low or "thigh" in low or "shin" in low:
            return "legs"
        if "neck" in low or "spine" in low or "arm" in low or "shoulder" in low or "chest" in low:
            return "torso"
        return None

    groups = [None] * len(joints)
    for i, node in enumerate(joints):
        g = own(names[i])
        walk = node
        while g is None:
            walk = parent.get(walk)
            if walk is None:
                break
            if walk in to_joint:
                g = own(names[to_joint[walk]])
        groups[i] = g
    return groups


def rasterise_groups(js, binary, primitive, size):
    """Paint every triangle into the atlas with the body part its bones say it is.

    This is the step that does not use colour, and that is the whole point of it — the atlas
    layout can be as chaotic as it likes and a texel is still head, torso, legs, feet or hand
    because a bone put it there.
    """
    uv = accessor(js, binary, primitive["attributes"]["TEXCOORD_0"])
    position = accessor(js, binary, primitive["attributes"]["POSITION"])
    joints = accessor(js, binary, primitive["attributes"]["JOINTS_0"]).astype(int)
    weights = accessor(js, binary, primitive["attributes"]["WEIGHTS_0"])
    indices = accessor(js, binary, primitive["indices"]).astype(int).ravel()

    groups = bone_groups(js)
    # `face` is last so it paints over `head`: it is a slice *of* the head rather than a part
    # beside it, and it exists to keep the eyes out of the hair.
    order = ["hand", "head", "torso", "legs", "feet", "face"]
    slot = {name: i + 1 for i, name in enumerate(order)}

    dominant = joints[np.arange(len(joints)), weights.argmax(1)]
    vertex_group = np.array([slot.get(groups[j], 0) if j < len(groups) else 0
                             for j in dominant], dtype=np.uint8)

    tris = indices.reshape(-1, 3)
    # A triangle takes the part its heaviest-bound corner has, so a triangle straddling a joint
    # goes with the bone that actually moves it.
    corner_weight = weights.max(1)[tris]
    tri_group = vertex_group[tris[np.arange(len(tris)), corner_weight.argmax(1)]]

    # --- The face, carved out of the head ---
    #
    # Everything on the skull that is not skin-coloured is hair, and the eyes are the exception:
    # sclera is white and a pupil is near-black, so neither reads as skin and both would recolour
    # with the hair — a character blinking in whatever colour was picked. Blond gave it away.
    #
    # These files are Y-up and face +Z, so the face is the front of the head's own box, in a band
    # around the middle of its height. Above that band is fringe and bun, which *are* hair; below
    # it is the chin, which is skin either way.
    head_vertices = position[np.isin(np.arange(len(position)),
                                     tris[tri_group == slot["head"]].ravel())]
    if len(head_vertices):
        low, high = head_vertices.min(0), head_vertices.max(0)
        depth, height = high[2] - low[2], max(high[1] - low[1], 1e-6)
        centre = position[tris].mean(1)
        # **Half the depth of the skull, not a quarter.** An eye is a sphere set *into* the head,
        # so its triangles sit well behind the face's outer surface — a shallow wedge misses them
        # entirely and the first blond character looked out through yellow eyes. The height band
        # is what keeps the wedge from swallowing the fringe above it.
        forward = centre[:, 2] >= high[2] - depth * 0.5
        band = (centre[:, 1] - low[1]) / height
        is_face = forward & (band >= 0.10) & (band <= 0.62) & (tri_group == slot["head"])
        tri_group[is_face] = slot["face"]

    px = np.clip(uv[:, 0] * size, 0, size - 1)
    py = np.clip(uv[:, 1] * size, 0, size - 1)

    image = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(image)
    for part in range(1, len(order) + 1):
        for tri in tris[tri_group == part]:
            draw.polygon([(px[tri[0]], py[tri[0]]), (px[tri[1]], py[tri[1]]),
                          (px[tri[2]], py[tri[2]])], fill=int(part))

    # **Grown by a few texels into the gaps between islands.** A triangle's own footprint stops
    # exactly at the island's edge and the renderer's bilinear filter reaches past it, so without
    # this every seam samples a texel the recolour never touched and each garment gets a pale
    # outline around it.
    #
    # Grown by *nearest label*, not by a max filter. A max filter grows whichever label happens
    # to have the largest number, which put the feet — 5, the highest — over every gap on the
    # sheet and painted a fifth of the atlas as shoe.
    painted = np.array(image)
    reach = np.stack([np.array(Image.fromarray(((painted == part) * 255).astype(np.uint8))
                                    .filter(ImageFilter.BoxBlur(3)), dtype=np.uint16)
                      for part in range(1, len(order) + 1)])
    grown = (reach.argmax(0) + 1).astype(np.uint8)
    grown[reach.max(0) == 0] = 0            # nowhere near anything: leave it unassigned
    grown[painted > 0] = painted[painted > 0]
    return grown, order


def classify(atlas, parts, order):
    """Cloth or skin, per texel, within each body part."""
    rgb = atlas.astype(np.float64)
    total = rgb.sum(2, keepdims=True)
    total[total < 1] = 1
    chroma = (rgb / total)[:, :, :2]
    luma = rgb @ np.array([0.2126, 0.7152, 0.0722])

    slot = {name: i + 1 for i, name in enumerate(order)}
    hand = parts == slot["hand"]
    if hand.sum() < 500:
        raise SystemExit("no hand texels — cannot measure this character's skin")
    skin_rgb = np.median(rgb[hand], axis=0)
    skin_chroma = skin_rgb[:2] / max(skin_rgb.sum(), 1)
    skin_luma = float(luma[hand].mean())

    # Same two tests the engine used, and for the same reasons: chromaticity because the atlas
    # paints its own shading in, and a brightness floor because brown hair is, chromatically,
    # dark skin.
    is_skin = (np.linalg.norm(chroma - skin_chroma, axis=2) <= 0.055) & (luma >= skin_luma * 0.45)

    region = np.zeros(parts.shape, dtype=np.uint8)
    # **The white of an eye, wherever the wedge missed it.** These characters have big eyes set
    # deep into the skull, and how deep varies enough between them that a geometric wedge tuned
    # to one leaves the other looking out through whatever colour the hair was painted. But
    # sclera has a property no hair has: it is bright *and* colourless. Hair is either coloured
    # (brown, ginger) or dark (black) — never both bright and grey.
    neutral = np.linalg.norm(chroma - 1.0 / 3.0, axis=2) <= 0.035
    is_eye = neutral & (luma >= 0.72 * float(luma.max()))

    region[(parts == slot["head"]) & ~is_skin & ~is_eye] = HAIR
    region[(parts == slot["torso"]) & ~is_skin] = TOP
    region[(parts == slot["legs"]) & ~is_skin] = BOTTOMS
    # Below the ankle there is nothing but shoe, and the skin test would fail there anyway —
    # a tan loafer *is* skin coloured.
    region[parts == slot["feet"]] = SHOES
    region[parts == slot["hand"]] = SKIN
    region[parts == slot["face"]] = SKIN

    # **Outvote the speckle.** A lone texel that read as cloth inside a field of skin is noise
    # from a JPEG ringing artefact, not a garment. A mode filter over a small window removes it
    # and leaves every real edge where it was.
    return majority(region, radius=3)


def majority(labels, radius):
    """Per-texel mode over a square window, done as one pass per label."""
    counts = np.zeros((len(REGION_NAMES),) + labels.shape, dtype=np.uint16)
    for value in range(len(REGION_NAMES)):
        mask = Image.fromarray(((labels == value) * 255).astype(np.uint8))
        blurred = mask.filter(ImageFilter.BoxBlur(radius))
        counts[value] = np.array(blurred, dtype=np.uint16)
    return counts.argmax(0).astype(np.uint8)


# --------------------------------------------------------------------------- recolour

def to_hsv(rgb):
    out = np.array(Image.fromarray(rgb.astype(np.uint8), "RGB").convert("HSV"))
    return out.astype(np.float64)


def repaint(atlas, mask, hex_colour):
    """Take hue and saturation from the asked-for colour; keep the texture's *shading*.

    A multiply can only darken — a white polo × red is a fine red, and dark green shorts × red
    is near-black — and half this cast wears something dark. So hue and saturation are taken
    whole and the value channel carries the painting across: the fold shadows, the seams and the
    sheen along a sleeve all live in value and none of them are in the hue.

    **But value is not kept as it was, it is re-levelled**, and that is the difference between
    working and nearly working. Keeping it outright means a colour can only ever be as bright as
    what it replaced, so asking dark brown hair for blond gives olive — the right hue at the
    wrong brightness, which reads as neither. Instead the region's *median* value is moved onto
    the target's and every texel scaled by the same factor, so the garment lands at the asked-for
    brightness and keeps its own variation around it.
    """
    value = int(hex_colour.lstrip("#"), 16)
    target = np.array([[[value >> 16 & 255, value >> 8 & 255, value & 255]]], dtype=np.uint8)
    wanted = to_hsv(target)[0, 0]

    hsv = to_hsv(atlas)
    hsv[mask, 0] = wanted[0]
    # Scaled rather than replaced, so a garment with a printed pattern keeps the pattern.
    hsv[mask, 1] = np.clip(hsv[mask, 1] * 0.35 + wanted[1] * 0.85, 0, 255)

    median = float(np.median(hsv[mask, 2]))
    if median > 1:
        gain = float(wanted[2]) / median
        # Bounded, because an unbounded lift clips a whole garment to white and loses the folds
        # with it. Beyond this the answer is a different model, not a different number.
        gain = min(max(gain, 0.35), 2.8)
        hsv[mask, 2] = np.clip(hsv[mask, 2] * gain, 0, 255)
    return np.array(Image.fromarray(hsv.astype(np.uint8), "HSV").convert("RGB"))


# --------------------------------------------------------------------------- driver

def process(key, args):
    path = os.path.join(MODELS, f"{key}.glb")
    js, binary = load_glb(path)
    primitive = js["meshes"][0]["primitives"][0]
    atlas = np.array(Image.open(__import__("io").BytesIO(
        base_colour_image(js, binary, primitive))).convert("RGB"))
    size = atlas.shape[0]

    parts, order = rasterise_groups(js, binary, primitive, size)
    region = classify(atlas, parts, order)

    tally = {REGION_NAMES[v]: int((region == v).sum()) for v in range(len(REGION_NAMES))}
    covered = 100 * (region != SKIN).sum() / region.size
    print(f"{key:14s} {covered:5.1f}% of the atlas is outfit   {tally}")

    if args.preview:
        blend = (atlas * 0.45 + PREVIEW[region] * 0.55).astype(np.uint8)
        blend[region == SKIN] = atlas[region == SKIN]
        out = os.path.join(args.preview_dir, f"{key}_regions.png")
        Image.fromarray(blend).save(out)
        print(f"               preview → {out}")

    if args.write:
        os.makedirs(OUT_DIR, exist_ok=True)
        for name, recipe in OUTFITS.items():
            painted = atlas.copy()
            for target_region, colour in recipe.items():
                painted = repaint(painted, region == target_region, colour)
            out = os.path.join(OUT_DIR, f"{key}_{name}.jpg")
            Image.fromarray(painted).save(out, quality=92, subsampling=0)
            print(f"               {name:8s} → {os.path.relpath(out, ROOT)} "
                  f"({os.path.getsize(out) // 1024} KB)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--models", nargs="*", default=MODEL_KEYS)
    parser.add_argument("--preview", action="store_true",
                        help="write a picture of the mask over the atlas, and stop")
    parser.add_argument("--preview-dir", default="/tmp")
    parser.add_argument("--write", action="store_true",
                        help="write the outfit textures")
    args = parser.parse_args()
    if not args.preview and not args.write:
        args.preview = True
    for key in args.models:
        process(key, args)


if __name__ == "__main__":
    main()
