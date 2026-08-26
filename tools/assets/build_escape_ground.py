#!/usr/bin/env python3
"""Pack the main building's night background into a one-quad textured .glb.

The School Escape minigame is a `WorldRenderedMinigame`, and those have no map layer —
their world is `SceneModel`s and primitives. The overworld draws the main building from
chunked tiles of `new_background.png`; this gives the minigame the same picture as a
single textured quad it can stand `walls.glb` on top of.

Vertices are written directly in **render space** (x right, y = −plan_y, z up), so the
Swift side places the model with an identity transform — no Y-up fixup, no offset. Both
windings are emitted so the floor can never be culled away by a winding mistake; four
triangles is free.

    python3 tools/assets/build_escape_ground.py

Writes assets/main_building/night_ground.glb (~1.5 MB: a 4096-wide JPEG inside a glb).
"""
import io
import json
import os
import struct

from PIL import Image

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(REPO, "assets/main_building/new_background.png")
DST = os.path.join(REPO, "assets/main_building/night_ground.glb")

MAP_W, MAP_H = 5584.0, 3072.0
TEX_W = 4096  # longest edge of the embedded texture

def main():
    image = Image.open(SRC).convert("RGB")
    scale = TEX_W / image.width
    image = image.resize((TEX_W, round(image.height * scale)), Image.LANCZOS)
    jpeg = io.BytesIO()
    image.save(jpeg, "JPEG", quality=84)
    jpeg = jpeg.getvalue()

    hw, hh = MAP_W / 2, MAP_H / 2
    # Plan-space corners, and their UVs in the background image (origin top-left).
    corners = [(-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh)]
    positions = b"".join(struct.pack("<3f", x, -y, 0.0) for x, y in corners)
    normals = b"".join(struct.pack("<3f", 0.0, 0.0, 1.0) for _ in corners)
    uvs = b"".join(struct.pack("<2f", (x + hw) / MAP_W, (y + hh) / MAP_H)
                   for x, y in corners)
    # Both windings of both triangles — see the module docstring.
    indices = struct.pack("<12H", 0, 1, 2, 0, 2, 3, 2, 1, 0, 3, 2, 0)

    binary = bytearray()
    views = []

    def view(payload, target=None):
        while len(binary) % 4:
            binary.append(0)
        entry = {"buffer": 0, "byteOffset": len(binary), "byteLength": len(payload)}
        if target:
            entry["target"] = target
        binary.extend(payload)
        views.append(entry)
        return len(views) - 1

    accessors = [
        {"bufferView": view(positions, 34962), "componentType": 5126, "count": 4,
         "type": "VEC3", "min": [-hw, -hh, 0.0], "max": [hw, hh, 0.0]},
        {"bufferView": view(normals, 34962), "componentType": 5126, "count": 4,
         "type": "VEC3"},
        {"bufferView": view(uvs, 34962), "componentType": 5126, "count": 4,
         "type": "VEC2"},
        {"bufferView": view(indices, 34963), "componentType": 5123, "count": 12,
         "type": "SCALAR"},
    ]
    image_view = view(jpeg)

    root = {
        "asset": {"version": "2.0", "generator": "tools/assets/build_escape_ground.py"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"mesh": 0, "name": "night_ground"}],
        "meshes": [{"name": "night_ground", "primitives": [{
            "attributes": {"POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2},
            "indices": 3,
            "material": 0,
        }]}],
        "materials": [{
            "name": "night_ground",
            "pbrMetallicRoughness": {
                "baseColorFactor": [1.0, 1.0, 1.0, 1.0],
                "baseColorTexture": {"index": 0},
                "roughnessFactor": 1.0,
                "metallicFactor": 0.0,
            },
        }],
        "images": [{"bufferView": image_view, "mimeType": "image/jpeg"}],
        "textures": [{"source": 0}],
        "accessors": accessors,
        "bufferViews": views,
        "buffers": [{"byteLength": len(binary)}],
    }

    js = bytearray(json.dumps(root, separators=(",", ":")).encode("utf-8"))
    while len(js) % 4:
        js.append(0x20)
    while len(binary) % 4:
        binary.append(0)
    total = 12 + 8 + len(js) + 8 + len(binary)
    with open(DST, "wb") as handle:
        handle.write(struct.pack("<III", 0x46546C67, 2, total))
        handle.write(struct.pack("<II", len(js), 0x4E4F534A))
        handle.write(js)
        handle.write(struct.pack("<II", len(binary), 0x004E4942))
        handle.write(binary)
    print(f"wrote {os.path.relpath(DST, REPO)} ({total / 1024:.0f} KB, "
          f"texture {image.width}x{image.height})")

if __name__ == "__main__":
    main()
