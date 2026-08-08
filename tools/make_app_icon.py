#!/usr/bin/env python3
"""Build the Joel's World app icon from the character art.

Two teachers (Mr Hardy, Ms Crosbie) flank the pupil on a white background.

The source portraits are painted on off-white paper, so each one is matted in
two passes. A tight flood-fill runs over a copy where paper grain above a
luminance floor has been clipped to pure white, which lets the fill sweep the
whole background without leaking through the line art. Inside the flooded
region alpha is then ramped by the *original* pixel's lightness, so anywhere
the fill did squeeze through a gap into dark artwork (Mr Hardy's suit) stays
opaque.

Writes native/JoelsWorld/Assets.xcassets/AppIcon.appiconset/. The Xcode target
uses a synchronised folder group, so the catalogue is picked up automatically.

Usage:  python3 tools/make_app_icon.py        (needs Pillow)
"""
import json
import pathlib
from PIL import Image, ImageDraw, ImageFilter

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC_DIR = ROOT / "original_images"
ICONSET = ROOT / "native/JoelsWorld/Assets.xcassets/AppIcon.appiconset"

SIZE = 1024
WHITE = (255, 255, 255)
MARK = (255, 0, 255)  # scratch colour the background flood-fill is painted in
RIM = 15  # MaxFilter window for the white sticker rim (odd)

# Matting thresholds, in min-channel luminance.
CLIP = 228  # at/above this, paper grain is flattened before the flood-fill
LIGHT = 238  # at/above this, a flooded pixel is background
DARK = 198  # at/below this, a flooded pixel is artwork and is kept

# Landmarks measured off the source art, in source pixels:
# fx = horizontal centre of the face, top = top of hair/hat, chin = chin line.
CHARS = {
    "mr_hardy": dict(fx=400, top=55, chin=590),
    "girl_age_8": dict(fx=450, top=40, chin=510),
    "ms_crosbie": dict(fx=450, top=45, chin=510),
}

# Where each head lands on the canvas: face centre x, hair top y, head height.
# The pupil is listed last so she composites in front, centred and largest.
# Sizes are chosen so every torso runs off the bottom edge (see the bleed
# check in build()) while leaving white margin at the top and sides.
LAYOUT = [
    ("mr_hardy", dict(x=174, top=240, head=386)),
    ("ms_crosbie", dict(x=790, top=240, head=386)),
    ("girl_age_8", dict(x=420, top=358, head=418)),
]


def matte(name):
    """Load a portrait and knock the off-white paper background out to alpha."""
    src = Image.open(SRC_DIR / f"{name}.png").convert("RGB")
    w, h = src.size

    # Flatten paper grain to flat white so a tight flood-fill can cross it.
    # Interior whites (the pupil's shirt) go white too, but they are enclosed
    # by line art, so the fill never reaches them and they stay opaque.
    flat = src.filter(ImageFilter.MedianFilter(3))
    fpx = flat.load()
    for y in range(h):
        for x in range(w):
            r, g, b = fpx[x, y]
            if r >= CLIP and g >= CLIP and b >= CLIP:
                fpx[x, y] = WHITE
    for x in range(0, w, 4):
        for seed in ((x, 0), (x, h - 1)):
            if flat.getpixel(seed) != MARK:
                ImageDraw.floodfill(flat, seed, MARK, thresh=6)
    for y in range(0, h, 4):
        for seed in ((0, y), (w - 1, y)):
            if flat.getpixel(seed) != MARK:
                ImageDraw.floodfill(flat, seed, MARK, thresh=6)

    mask = Image.new("L", (w, h), 255)
    mpx, fpx, spx = mask.load(), flat.load(), src.load()
    for y in range(h):
        for x in range(w):
            if fpx[x, y] != MARK:
                continue
            lum = min(spx[x, y])
            if lum >= LIGHT:
                mpx[x, y] = 0
            elif lum > DARK:
                mpx[x, y] = int(255 * (LIGHT - lum) / (LIGHT - DARK))

    out = src.convert("RGBA")
    out.putalpha(mask.filter(ImageFilter.GaussianBlur(0.6)))
    return out


def place(name, spec):
    """Scale and position one matted portrait for the icon canvas."""
    src = matte(name)
    m = CHARS[name]
    scale = spec["head"] / (m["chin"] - m["top"])
    img = src.resize(
        (int(round(src.width * scale)), int(round(src.height * scale))), Image.LANCZOS
    )
    ox = int(round(spec["x"] - m["fx"] * scale))
    oy = int(round(spec["top"] - m["top"] * scale))
    return img, (ox, oy)


def rimmed(img):
    """Add a white sticker rim so overlapping figures read apart from each other."""
    a = img.getchannel("A").filter(ImageFilter.MaxFilter(RIM))
    a = a.filter(ImageFilter.GaussianBlur(1.0)).point(lambda v: 255 if v > 60 else 0)
    rim = Image.new("RGBA", img.size, WHITE + (0,))
    rim.putalpha(a)
    rim.alpha_composite(img)
    return rim


def build():
    canvas = Image.new("RGBA", (SIZE, SIZE), WHITE + (255,))
    for name, spec in LAYOUT:
        img, off = place(name, spec)
        box = img.getchannel("A").point(lambda v: 255 if v > 128 else 0).getbbox()
        bottom = off[1] + box[3]
        if bottom < SIZE:
            raise SystemExit(
                f"{name}: torso ends at y={bottom}, short of the {SIZE}px bottom edge; "
                "raise its 'head' size in LAYOUT so the body bleeds off-canvas"
            )
        canvas.alpha_composite(rimmed(img), off)
    # App Store icons must be fully opaque, so drop the alpha channel.
    return canvas.convert("RGB")


def main():
    icon = build()
    ICONSET.mkdir(parents=True, exist_ok=True)
    icon.save(ICONSET / "AppIcon.png")
    (ICONSET / "Contents.json").write_text(
        json.dumps(
            {
                "images": [
                    {
                        "filename": "AppIcon.png",
                        "idiom": "universal",
                        "platform": "ios",
                        "size": "1024x1024",
                    }
                ],
                "info": {"author": "xcode", "version": 1},
            },
            indent=2,
        )
        + "\n"
    )
    catalog = ICONSET.parent / "Contents.json"
    if not catalog.exists():
        catalog.write_text(
            json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n"
        )
    print(f"wrote {ICONSET.relative_to(ROOT)}/AppIcon.png ({icon.size[0]}px, opaque)")


if __name__ == "__main__":
    main()
