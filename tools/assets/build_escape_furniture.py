#!/usr/bin/env python3
"""Give every painted object in the main building a 3D body for School Escape.

Joel's first-person camera lives at eye height, where furniture that is only painted on
the floor reads as flat nonsense. The good news is the clip mask already knows every
painted object's footprint — each one is a blocked blob. This finds those blobs, skips
the ones a real .glb already stands on (cafeteria tables, classroom desks — read from
`objects.json` plus the grid `SchoolEscapeMap.paintedDesks` places), and turns the rest
into simple coloured boxes: steel in the kitchen, wood in the office and corridors, white
in the toilets. At night, behind a torch-less camera, a box the right size in the right
place is 90% of a cupboard.

Writes native/Engine/World/Minigames/SchoolEscape/SchoolEscapeFurniture.swift — generated
code, do not edit by hand; rerun this after repainting the map or the mask.

    python3 tools/assets/build_escape_furniture.py
"""
import collections
import json
import os

from PIL import Image

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MASK = os.path.join(REPO, "assets/main_building/clip_mask.png")
OBJECTS = os.path.join(REPO, "data/main_building/objects.json")
OUT = os.path.join(REPO, "native/Engine/World/Minigames/SchoolEscape/SchoolEscapeFurniture.swift")

MAP_W, MAP_H = 5584.0, 3072.0

# Must mirror SchoolEscapeMap.paintedDesks (the desks+chairs placed in the west rooms),
# plus the two hand-placed desks and the chest.
EXTRA_PLACEMENTS = (
    [(x, y) for y in (550, 730, 900, 1075) for x in (-2410, -2245, -2075)]
    + [(x, y) for y in (555, 730, 905) for x in (-915, -705, -495)]
    + [(-2615, 520), (-2190, -1070), (-1380, 1120)]
)

# (region test, hex colour, box height) — first match wins, top to bottom.
REGIONS = [
    (lambda x, y: x > 1850 and y < -300, "#8f979c", 110),   # kitchen: steel counters
    (lambda x, y: x < -1500 and y < -700, "#5d3f24", 150),  # office: dark wood shelves
    (lambda x, y: -400 < x < 400 and y < -450, "#d8d8d8", 60),  # toilets: white china
    (lambda x, y: -300 < y < 250, "#71512f", 55),           # corridors: benches
]
DEFAULT = ("#6b4a2a", 90)

# Painted furniture that stands *against a wall* merges into the wall's blob in the mask
# and cannot be found automatically, so the big pieces are placed by hand off the map
# image: the kitchen's two counter runs, the office shelves, the reception desk's L, and
# the toilets. (x, y, w, l, h, colour).
HAND_PLACED = [
    (1930, -665, 120, 550, 110, "#8f979c"),    # kitchen counter, left run
    (2600, -725, 200, 650, 110, "#8f979c"),    # kitchen counter, right run (stoves)
    (-2455, -1300, 200, 90, 150, "#5d3f24"),   # office shelves, top wall west
    (-1800, -1300, 200, 90, 150, "#5d3f24"),   # office shelves, top wall east
    (-780, -40, 380, 80, 85, "#6b4a2a"),       # reception desk, long side
    (-940, 30, 80, 160, 85, "#6b4a2a"),        # reception desk, short side of the L
    (-250, -700, 64, 72, 55, "#d8d8d8"),       # left toilet
    (-95, -655, 64, 48, 75, "#d8d8d8"),        # left sink
    (75, -700, 64, 72, 55, "#d8d8d8"),         # right toilet
    (215, -655, 64, 48, 75, "#d8d8d8"),        # right sink
]


def main():
    mask = Image.open(MASK).convert("RGB")
    width, height = mask.size
    sx, sy = width / MAP_W, height / MAP_H
    pixels = mask.load()

    def is_blocked(x, y):
        r, g, b = pixels[x, y]
        return not ((r == 255 and g == 255 and b == 255) or (r == 0 and g == 255 and b == 0))

    seen = [[False] * width for _ in range(height)]
    blobs = []
    for y0 in range(height):
        for x0 in range(width):
            if not is_blocked(x0, y0) or seen[y0][x0]:
                continue
            queue = collections.deque([(x0, y0)])
            seen[y0][x0] = True
            count = 0
            min_x = max_x = x0
            min_y = max_y = y0
            while queue:
                x, y = queue.popleft()
                count += 1
                min_x, max_x = min(min_x, x), max(max_x, x)
                min_y, max_y = min(min_y, y), max(max_y, y)
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < width and 0 <= ny < height and is_blocked(nx, ny) \
                            and not seen[ny][nx]:
                        seen[ny][nx] = True
                        queue.append((nx, ny))
            blobs.append((count, min_x, min_y, max_x, max_y))

    placements = list(EXTRA_PLACEMENTS)
    for obj in json.load(open(OBJECTS)):
        if obj.get("shape") == "3d_model":
            placements.append((obj["x"], obj["y"]))

    boxes = []
    for count, x0, y0, x1, y1 in blobs:
        w = (x1 - x0 + 1) / sx
        l = (y1 - y0 + 1) / sy
        if count < 6 or w > 700 or l > 700:  # noise, or a wall/building
            continue
        cx = ((x0 + x1 + 1) / 2) / sx - MAP_W / 2
        cy = ((y0 + y1 + 1) / 2) / sy - MAP_H / 2
        if any(abs(px - cx) < 130 and abs(py - cy) < 130 for px, py in placements):
            continue  # a real model already stands here
        colour, box_height = DEFAULT
        for test, hex_colour, region_height in REGIONS:
            if test(cx, cy):
                colour, box_height = hex_colour, region_height
                break
        # Quantised to 16 px so repeated sizes share one GPU mesh; inset 6 px so the box
        # sits just inside its painted footprint rather than kissing the wall next to it.
        def q(value):
            return max(16, int(round((value - 6) / 16)) * 16)
        boxes.append((round(cx), round(cy), q(w), q(l), box_height, colour))
    boxes.extend(HAND_PLACED)

    lines = [
        "// Generated by tools/assets/build_escape_furniture.py — do not edit by hand.",
        "// A 3D box for every painted object the clip mask knows about that has no real",
        "// model standing on it. See the generator for the reasoning and the region colours.",
        "import simd",
        "",
        "enum SchoolEscapeFurniture {",
        "    /// (centre x, centre y, width, length, height, colour) in map pixels.",
        "    static let boxes: [(x: Double, y: Double, w: Float, l: Float, h: Float, hex: String)] = [",
    ]
    for cx, cy, w, l, h, colour in sorted(boxes, key=lambda b: (b[1], b[0])):
        lines.append(f'        ({cx}, {cy}, {w}, {l}, {h}, "{colour}"),')
    lines += [
        "    ]",
        "",
        "    static let primitives: [ScenePrimitive] = boxes.map { box in",
        "        ScenePrimitive(shape: .box(width: box.w, height: box.l, depth: box.h),",
        "                       transform: Float4x4.translation(SIMD3(Float(box.x),",
        "                                                             Float(-box.y),",
        "                                                             box.h / 2)),",
        "                       color: parseHexColor(box.hex),",
        "                       roughness: 0.85)",
        "    }",
        "}",
        "",
    ]
    with open(OUT, "w") as handle:
        handle.write("\n".join(lines))
    print(f"wrote {os.path.relpath(OUT, REPO)}: {len(boxes)} boxes")


if __name__ == "__main__":
    main()
