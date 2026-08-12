#!/usr/bin/env python3
"""Turn a flat floor plan into a room you can walk around in.

The overworld has exactly two sources of geometry: chunked ground images, and authored
`.glb` props. There is no runtime path for procedural shapes — `ScenePrimitiveRenderer`
belongs to the minigames. So a room built out of real walls has to arrive as a `.glb`,
and this is what builds it.

Input is one plan file — a list of wall segments and floor polygons in **exactly the
coordinates `objects.json` uses**, so a wall can be lined up against a desk by reading
the numbers off the map editor. Output is two files that stay in step because they come
from the same plan:

  * `<name>.glb`  — extruded, UV'd, textured walls and floor, placed as a single prop.
  * `clip_mask.png` — the walkability mask `ClipMask.swift` reads.

Keeping those two in one generator is the point. Hand-painting a mask to agree with
hand-modelled walls is how you end up with an invisible wall in a doorway.

    python3 tools/maps/extrude_room.py data/detention/room.json

Run with `--check` to print what it would build without writing anything.

Coordinates
-----------
The plan is 2D and top-down, same as the map editor: `x` right, `y` **down**, origin at
the centre of the map. Heights are the third number and are always measured up from the
floor.

`PropRenderer.transform` tips a glTF asset upright by 90° about X, because glTF is
authored Y-up and this world is Z-up. Composed with the world placement, a glTF vertex
`(gx, gy, gz)` lands at world `(gx, -gz, gy)`, and an object at `objects.json` position
`(ox, oy)` renders at `(ox, -oy)`. Equating the two, a plan point `(x, y)` at height `h`
is the glTF vertex `(x, h, y)` — which is the whole of the mapping, done once, in
`_gltf_point`. Place the generated prop at `x: 0, y: 0, z: 0, scale: 1` and the plan
coordinates *are* the world coordinates.

Winding and normals
-------------------
`Renderer` culls back faces with counter-clockwise fronts. Every box here is emitted
closed, with outward CCW faces, which is what lets you see the inside of the far wall
and not the inside of the near one.

What it deliberately does not do
--------------------------------
No ceiling — the camera looks down through it. No metallic/roughness *textures*, because
`GLTFLoader` reads those two as scalar factors only; a pack's packed ORM map has nowhere
to go and gets flattened to `roughness`/`metalness` numbers in the plan.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import struct
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Must match `ClipMask.scale` in native/Engine/World/ClipMask.swift.
CLIP_MASK_SCALE = 0.1

FLOAT = 5126
UINT32 = 5125
ARRAY_BUFFER = 34962
ELEMENT_ARRAY_BUFFER = 34963


# ---------------------------------------------------------------------------
# Geometry accumulation
# ---------------------------------------------------------------------------


class Surface:
    """Every triangle sharing one material, merged into one glTF primitive.

    One primitive becomes one `ModelGroup` and therefore one draw call, so the walls of
    a whole room cost the renderer the same as a single chair.
    """

    def __init__(self, material: str):
        self.material = material
        self.positions: list[tuple[float, float, float]] = []
        self.normals: list[tuple[float, float, float]] = []
        self.uvs: list[tuple[float, float]] = []
        self.indices: list[int] = []

    def add_triangle(self, verts, normal, uvs):
        base = len(self.positions)
        for v, uv in zip(verts, uvs):
            self.positions.append(v)
            self.normals.append(normal)
            self.uvs.append(uv)
        self.indices.extend((base, base + 1, base + 2))

    def add_quad(self, verts, normal, uvs):
        """`verts` counter-clockwise seen from the front."""
        self.add_triangle((verts[0], verts[1], verts[2]), normal, (uvs[0], uvs[1], uvs[2]))
        self.add_triangle((verts[0], verts[2], verts[3]), normal, (uvs[0], uvs[2], uvs[3]))

    @property
    def is_empty(self) -> bool:
        return not self.indices


class Builder:
    def __init__(self):
        self.surfaces: dict[str, Surface] = {}
        # Plan-space rectangles the walls occupy, for the clip mask: (x0, y0, x1, y1).
        self.blocked: list[tuple[float, float, float, float]] = []
        self.walkable: list[list[tuple[float, float]]] = []

    def surface(self, material: str) -> Surface:
        if material not in self.surfaces:
            self.surfaces[material] = Surface(material)
        return self.surfaces[material]


def _gltf_point(x: float, y: float, h: float) -> tuple[float, float, float]:
    """Plan `(x, y)` at height `h` → the glTF vertex. See the module docstring."""
    return (x, h, y)


# ---------------------------------------------------------------------------
# Boxes
# ---------------------------------------------------------------------------


def emit_box(builder: Builder, material: str, origin, u_axis, lo, hi, uv_scale: float):
    """A closed box in a wall-local frame.

    `origin` is a plan-space point, `u_axis` the unit direction along the wall in plan
    space. The local frame is `(u, up, w)` where `w = (-uy, ux)`; that handedness is
    what makes the frame a rotation rather than a reflection, so the unit-cube winding
    below survives into glTF space unflipped.

    `lo`/`hi` are `(u, height, w)` corners in that frame.
    """
    ux, uy = u_axis
    wx, wy = -uy, ux

    def point(lu, lh, lw):
        return _gltf_point(origin[0] + ux * lu + wx * lw,
                           origin[1] + uy * lu + wy * lw,
                           lh)

    def normal(nu, nh, nw):
        return (ux * nu + wx * nw, nh, uy * nu + wy * nw)

    u0, h0, w0 = lo
    u1, h1, w1 = hi
    if u1 - u0 <= 1e-6 or h1 - h0 <= 1e-6:
        return

    s = builder.surface(material)
    k = 1.0 / uv_scale

    # Vertical faces carry a continuous world-space UV: `v` runs negative going up, so
    # the texture stays unbroken across a lintel and its wall. Repeat wrap makes the
    # negative side free.
    # +w and -w — the two long faces.
    s.add_quad((point(u0, h0, w1), point(u1, h0, w1), point(u1, h1, w1), point(u0, h1, w1)),
               normal(0, 0, 1),
               ((u0 * k, -h0 * k), (u1 * k, -h0 * k), (u1 * k, -h1 * k), (u0 * k, -h1 * k)))
    s.add_quad((point(u1, h0, w0), point(u0, h0, w0), point(u0, h1, w0), point(u1, h1, w0)),
               normal(0, 0, -1),
               ((-u1 * k, -h0 * k), (-u0 * k, -h0 * k), (-u0 * k, -h1 * k), (-u1 * k, -h1 * k)))
    # +u and -u — the ends, exposed at a doorway reveal.
    s.add_quad((point(u1, h0, w1), point(u1, h0, w0), point(u1, h1, w0), point(u1, h1, w1)),
               normal(1, 0, 0),
               ((w1 * k, -h0 * k), (w0 * k, -h0 * k), (w0 * k, -h1 * k), (w1 * k, -h1 * k)))
    s.add_quad((point(u0, h0, w0), point(u0, h0, w1), point(u0, h1, w1), point(u0, h1, w0)),
               normal(-1, 0, 0),
               ((-w0 * k, -h0 * k), (-w1 * k, -h0 * k), (-w1 * k, -h1 * k), (-w0 * k, -h1 * k)))
    # +h and -h — the top is the one you actually see from a top-down camera.
    s.add_quad((point(u0, h1, w1), point(u1, h1, w1), point(u1, h1, w0), point(u0, h1, w0)),
               normal(0, 1, 0),
               ((u0 * k, w1 * k), (u1 * k, w1 * k), (u1 * k, w0 * k), (u0 * k, w0 * k)))
    s.add_quad((point(u0, h0, w0), point(u1, h0, w0), point(u1, h0, w1), point(u0, h0, w1)),
               normal(0, -1, 0),
               ((u0 * k, w0 * k), (u1 * k, w0 * k), (u1 * k, w1 * k), (u0 * k, w1 * k)))


# ---------------------------------------------------------------------------
# Walls
# ---------------------------------------------------------------------------


def build_wall(builder: Builder, wall: dict, defaults: dict):
    ax, ay = wall["from"]
    bx, by = wall["to"]
    dx, dy = bx - ax, by - ay
    length = math.hypot(dx, dy)
    if length < 1e-6:
        raise ValueError(f"wall from {wall['from']} to {wall['to']} has no length")
    axis = (dx / length, dy / length)

    height = float(wall.get("height", defaults["wall_height"]))
    thickness = float(wall.get("thickness", defaults["wall_thickness"]))
    material = wall.get("material", "wall")
    uv_scale = float(wall.get("uv_scale", defaults["uv_scale"]))
    half = thickness / 2

    # Openings, resolved to spans along the wall and sorted so the solid pieces between
    # them can be walked in one pass.
    openings = []
    for opening in wall.get("openings", []):
        width = float(opening["width"])
        centre = float(opening["at"]) * length
        sill = float(opening.get("sill", 0))
        top = sill + float(opening.get("height", height - sill))
        start = max(0.0, centre - width / 2)
        end = min(length, centre + width / 2)
        if end - start <= 1e-6:
            continue
        openings.append((start, end, sill, min(top, height),
                         opening.get("fill"), bool(opening.get("blocks", False))))
    openings.sort()

    cursor = 0.0
    for start, end, sill, top, fill, _ in openings:
        if start > cursor:
            emit_box(builder, material, (ax, ay), axis,
                     (cursor, 0, -half), (start, height, half), uv_scale)
        if sill > 0:  # a window: the wall below the sill still stands, and still blocks.
            emit_box(builder, material, (ax, ay), axis,
                     (start, 0, -half), (end, sill, half), uv_scale)
        if top < height - 1e-6:  # the lintel over a door.
            emit_box(builder, material, (ax, ay), axis,
                     (start, top, -half), (end, height, half), uv_scale)
        if fill:
            # A hole in a wall shows whatever is behind the map, which on a layer-less map is
            # the flat background colour — a window reads as a rectangle cut out of the world.
            # A thin pane in the opening is what makes it a window instead.
            pane = max(2.0, thickness / 8)
            emit_box(builder, fill, (ax, ay), axis,
                     (start, sill, -pane / 2), (end, top, pane / 2), uv_scale)
        cursor = max(cursor, end)
    if cursor < length:
        emit_box(builder, material, (ax, ay), axis,
                 (cursor, 0, -half), (length, height, half), uv_scale)

    skirting = wall.get("skirting", defaults.get("skirting"))
    if skirting:
        skirt_h = float(skirting if isinstance(skirting, (int, float)) else skirting["height"])
        proud = float(defaults.get("skirting_proud", 6))
        skirt_mat = wall.get("skirting_material", defaults.get("skirting_material", "skirting"))
        cursor = 0.0
        for start, end, sill, _, _, _ in openings:
            if sill > 0:  # a window has floor under it, and therefore skirting too.
                continue
            if start > cursor:
                emit_box(builder, skirt_mat, (ax, ay), axis,
                         (cursor, 0, -half - proud), (start, skirt_h, half + proud), uv_scale)
            cursor = max(cursor, end)
        if cursor < length:
            emit_box(builder, skirt_mat, (ax, ay), axis,
                     (cursor, 0, -half - proud), (length, skirt_h, half + proud), uv_scale)

    # Clip-mask footprint. A doorway at floor level is the only part of a wall you can
    # walk through, so it is the only part left out.
    def block(u0, u1, pad):
        corners = [(ax + axis[0] * u + (-axis[1]) * w, ay + axis[1] * u + axis[0] * w)
                   for u, w in ((u0, -pad), (u1, -pad), (u1, pad), (u0, pad))]
        xs = [c[0] for c in corners]
        ys = [c[1] for c in corners]
        builder.blocked.append((min(xs), min(ys), max(xs), max(ys)))

    pad = half + (float(defaults.get("skirting_proud", 6)) if skirting else 0)
    cursor = 0.0
    for start, end, sill, _, _, blocks in openings:
        if start > cursor:
            block(cursor, start, pad)
        # A window still has wall under it, and a `blocks` opening is a door that is shut.
        if sill > 0 or blocks:
            block(start, end, pad)
        cursor = max(cursor, end)
    if cursor < length:
        block(cursor, length, pad)


def build_block(builder: Builder, spec: dict, defaults: dict):
    """A free-standing solid — a pillar, a cupboard run, a plinth."""
    x, y, w, l = spec["rect"]
    height = float(spec.get("height", defaults["wall_height"]))
    material = spec.get("material", "wall")
    uv_scale = float(spec.get("uv_scale", defaults["uv_scale"]))
    emit_box(builder, material, (x, y + l / 2), (1.0, 0.0),
             (0, 0, -l / 2), (w, height, l / 2), uv_scale)
    builder.blocked.append((x, y, x + w, y + l))


# ---------------------------------------------------------------------------
# Floors
# ---------------------------------------------------------------------------


def triangulate(polygon: list[tuple[float, float]]) -> list[tuple[int, int, int]]:
    """Ear clipping for a simple polygon, no holes.

    Plan space is y-down, so the sign of the shoelace area is inverted relative to the
    usual maths convention; the winding is normalised here rather than trusted from the
    plan, because a floor authored the other way round would be culled away entirely.
    """
    n = len(polygon)
    if n < 3:
        return []
    area = sum(polygon[i][0] * polygon[(i + 1) % n][1] - polygon[(i + 1) % n][0] * polygon[i][1]
               for i in range(n)) / 2
    order = list(range(n)) if area > 0 else list(range(n))[::-1]

    def cross(o, a, b):
        return ((a[0] - o[0]) * (b[1] - o[1])) - ((a[1] - o[1]) * (b[0] - o[0]))

    def inside(p, a, b, c):
        d1, d2, d3 = cross(a, b, p), cross(b, c, p), cross(c, a, p)
        neg = d1 < 0 or d2 < 0 or d3 < 0
        pos = d1 > 0 or d2 > 0 or d3 > 0
        return not (neg and pos)

    remaining = list(order)
    triangles = []
    guard = 0
    while len(remaining) > 3 and guard < len(remaining) * len(remaining) + 16:
        guard += 1
        for i in range(len(remaining)):
            prev = polygon[remaining[i - 1]]
            cur = polygon[remaining[i]]
            nxt = polygon[remaining[(i + 1) % len(remaining)]]
            if cross(prev, cur, nxt) <= 0:
                continue
            others = [polygon[k] for k in remaining
                      if k not in (remaining[i - 1], remaining[i], remaining[(i + 1) % len(remaining)])]
            if any(inside(p, prev, cur, nxt) for p in others):
                continue
            triangles.append((remaining[i - 1], remaining[i], remaining[(i + 1) % len(remaining)]))
            remaining.pop(i)
            guard = 0
            break
        else:
            break
    if len(remaining) == 3:
        triangles.append(tuple(remaining))
    return triangles


def build_floor(builder: Builder, spec: dict, defaults: dict):
    polygon = [tuple(p) for p in spec["polygon"]]
    material = spec.get("material", "floor")
    uv_scale = float(spec.get("uv_scale", defaults["uv_scale"]))
    height = float(spec.get("height", 0))
    s = builder.surface(material)
    k = 1.0 / uv_scale

    for tri in triangulate(polygon):
        pts = [polygon[i] for i in tri]
        # Wound so the face points up once mapped: plan y-down flips the handedness, so
        # the triangle is emitted reversed from its plan-space order.
        verts = [_gltf_point(p[0], p[1], height) for p in reversed(pts)]
        uvs = [(p[0] * k, p[1] * k) for p in reversed(pts)]
        s.add_triangle(verts, (0.0, 1.0, 0.0), uvs)

    builder.walkable.append(polygon)


# ---------------------------------------------------------------------------
# glTF / GLB output
# ---------------------------------------------------------------------------


def _pad(data: bytearray, filler: int):
    while len(data) % 4:
        data.append(filler)


def write_glb(path: str, builder: Builder, plan: dict) -> dict:
    materials_spec = plan.get("materials", {})
    binary = bytearray()
    buffer_views: list[dict] = []
    accessors: list[dict] = []
    images: list[dict] = []
    textures: list[dict] = []
    gltf_materials: list[dict] = []
    material_index: dict[str, int] = {}
    image_cache: dict[str, int] = {}

    def add_view(payload: bytes, target=None) -> int:
        _pad(binary, 0)
        offset = len(binary)
        binary.extend(payload)
        view = {"buffer": 0, "byteOffset": offset, "byteLength": len(payload)}
        if target is not None:
            view["target"] = target
        buffer_views.append(view)
        return len(buffer_views) - 1

    def add_accessor(payload: bytes, count: int, ctype: int, atype: str, target,
                     minimum=None, maximum=None) -> int:
        acc = {"bufferView": add_view(payload, target), "componentType": ctype,
               "count": count, "type": atype}
        if minimum is not None:
            acc["min"] = minimum
            acc["max"] = maximum
        accessors.append(acc)
        return len(accessors) - 1

    def add_texture(relative: str) -> int:
        if relative in image_cache:
            return image_cache[relative]
        full = relative if os.path.isabs(relative) else os.path.join(REPO, relative)
        with open(full, "rb") as handle:
            payload = handle.read()
        mime = "image/png" if full.lower().endswith(".png") else "image/jpeg"
        images.append({"bufferView": add_view(payload), "mimeType": mime})
        # No sampler: glTF defaults to repeat wrapping, which is what the world-scale
        # UVs above need, and `Renderer` binds a repeat sampler for props regardless.
        textures.append({"source": len(images) - 1})
        image_cache[relative] = len(textures) - 1
        return len(textures) - 1

    def material(name: str) -> int:
        if name in material_index:
            return material_index[name]
        spec = materials_spec.get(name, {})
        colour = spec.get("color", "#b0b0b0")
        pbr = {
            "baseColorFactor": list(hex_to_linear(colour)) + [1.0],
            "roughnessFactor": float(spec.get("roughness", 0.9)),
            "metallicFactor": float(spec.get("metalness", 0.0)),
        }
        if spec.get("texture"):
            pbr["baseColorTexture"] = {"index": add_texture(spec["texture"])}
            # A base-colour texture multiplies the factor, so a tinted factor would
            # double-darken a pack's albedo. White unless the plan says otherwise.
            if "color" not in spec:
                pbr["baseColorFactor"] = [1.0, 1.0, 1.0, 1.0]
        entry = {"name": name, "pbrMetallicRoughness": pbr, "doubleSided": False}
        if spec.get("normal_texture"):
            entry["normalTexture"] = {"index": add_texture(spec["normal_texture"]),
                                      "scale": float(spec.get("normal_scale", 1.0))}
        gltf_materials.append(entry)
        material_index[name] = len(gltf_materials) - 1
        return material_index[name]

    primitives = []
    for name, surface in builder.surfaces.items():
        if surface.is_empty:
            continue
        positions = b"".join(struct.pack("<3f", *p) for p in surface.positions)
        normals = b"".join(struct.pack("<3f", *n) for n in surface.normals)
        uvs = b"".join(struct.pack("<2f", *t) for t in surface.uvs)
        indices = b"".join(struct.pack("<I", i) for i in surface.indices)

        xs = [p[0] for p in surface.positions]
        ys = [p[1] for p in surface.positions]
        zs = [p[2] for p in surface.positions]
        pos_accessor = add_accessor(positions, len(surface.positions), FLOAT, "VEC3",
                                    ARRAY_BUFFER,
                                    [min(xs), min(ys), min(zs)], [max(xs), max(ys), max(zs)])
        primitives.append({
            "attributes": {
                "POSITION": pos_accessor,
                "NORMAL": add_accessor(normals, len(surface.normals), FLOAT, "VEC3", ARRAY_BUFFER),
                "TEXCOORD_0": add_accessor(uvs, len(surface.uvs), FLOAT, "VEC2", ARRAY_BUFFER),
            },
            "indices": add_accessor(indices, len(surface.indices), UINT32, "SCALAR",
                                    ELEMENT_ARRAY_BUFFER),
            "material": material(name),
        })

    root = {
        "asset": {"version": "2.0", "generator": "tools/maps/extrude_room.py"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"mesh": 0, "name": plan.get("name", "room")}],
        "meshes": [{"name": plan.get("name", "room"), "primitives": primitives}],
        "materials": gltf_materials,
        "accessors": accessors,
        "bufferViews": buffer_views,
        "buffers": [{"byteLength": len(binary)}],
    }
    if images:
        root["images"] = images
        root["textures"] = textures

    json_chunk = bytearray(json.dumps(root, separators=(",", ":")).encode("utf-8"))
    _pad(json_chunk, 0x20)
    bin_chunk = bytearray(binary)
    _pad(bin_chunk, 0)

    total = 12 + 8 + len(json_chunk) + 8 + len(bin_chunk)
    with open(path, "wb") as handle:
        handle.write(struct.pack("<III", 0x46546C67, 2, total))
        handle.write(struct.pack("<II", len(json_chunk), 0x4E4F534A))
        handle.write(json_chunk)
        handle.write(struct.pack("<II", len(bin_chunk), 0x004E4942))
        handle.write(bin_chunk)

    return {"primitives": len(primitives), "triangles": sum(len(s.indices) // 3
                                                            for s in builder.surfaces.values()),
            "bytes": total}


def hex_to_linear(value: str) -> tuple[float, float, float]:
    """`#rrggbb` → linear, because glTF factors are linear and a picked colour is sRGB."""
    value = value.lstrip("#")
    srgb = [int(value[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    return tuple(c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in srgb)


# ---------------------------------------------------------------------------
# Clip mask
# ---------------------------------------------------------------------------


def write_clip_mask(path: str, builder: Builder, plan: dict) -> dict:
    try:
        from PIL import Image, ImageDraw
    except ImportError:
        return {"skipped": "Pillow is not installed (pip3 install Pillow)"}

    map_w = float(plan["map"]["width"])
    map_h = float(plan["map"]["height"])
    # Rasterised at exactly the scale `ClipMask` reads at. Anything larger is resampled
    # nearest-neighbour on load, and a doorway one pixel wide does not survive that —
    # see the note in ClipMask.swift about detention's own mask sealing in the spawn.
    width = round(map_w * CLIP_MASK_SCALE)
    height = round(map_h * CLIP_MASK_SCALE)

    def to_px(x, y):
        return ((x + map_w / 2) * CLIP_MASK_SCALE, (y + map_h / 2) * CLIP_MASK_SCALE)

    image = Image.new("RGB", (width, height), (0, 0, 0))
    draw = ImageDraw.Draw(image)

    for polygon in builder.walkable:
        draw.polygon([to_px(*p) for p in polygon], fill=(255, 255, 255))
    for x0, y0, x1, y1 in builder.blocked:
        # A mask pixel is 10 world units — a twentieth of a character — and a wall face almost
        # never lands on a pixel boundary. Rounded **out**, so a partly-covered pixel counts as
        # wall: the player stops a few centimetres short of the plaster. Rounded the other way
        # they would stand inside it, and the camera looks straight down on that.
        px0, py0 = to_px(x0, y0)
        px1, py1 = to_px(x1, y1)
        draw.rectangle([math.floor(px0), math.floor(py0),
                        math.ceil(px1) - 1, math.ceil(py1) - 1], fill=(0, 0, 0))
    # Last word, for the cases the geometry gets wrong: a threshold that needs forcing
    # open, or a corner behind a prop that should never have been walkable.
    for patch in plan.get("paint", []):
        x, y, w, l = patch["rect"]
        colour = (255, 255, 255) if patch.get("walkable", True) else (0, 0, 0)
        draw.rectangle([to_px(x, y), to_px(x + w, y + l)], fill=colour)

    image.save(path)
    walkable = sum(1 for p in image.getdata() if p == (255, 255, 255))
    return {"size": f"{width}x{height}", "walkable_pixels": walkable}


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def build(plan_path: str, glb_path: str | None, mask_path: str | None, check: bool):
    with open(plan_path) as handle:
        plan = json.load(handle)

    defaults = {"wall_height": 300, "wall_thickness": 40, "uv_scale": 256}
    defaults.update(plan.get("defaults", {}))

    builder = Builder()
    for floor in plan.get("floors", []):
        build_floor(builder, floor, defaults)
    for wall in plan.get("walls", []):
        build_wall(builder, wall, defaults)
    for block in plan.get("blocks", []):
        build_block(builder, block, defaults)

    tris = sum(len(s.indices) // 3 for s in builder.surfaces.values())
    print(f"{plan.get('name', plan_path)}: {len(plan.get('walls', []))} wall(s), "
          f"{len(plan.get('floors', []))} floor(s), {len(plan.get('blocks', []))} block(s) "
          f"→ {tris} triangles across {len(builder.surfaces)} material(s)")
    if check:
        for name, surface in builder.surfaces.items():
            print(f"  {name}: {len(surface.indices) // 3} triangles")
        return

    if glb_path:
        stats = write_glb(glb_path, builder, plan)
        print(f"  wrote {os.path.relpath(glb_path, REPO)} "
              f"({stats['bytes'] / 1024:.1f} KB, {stats['primitives']} primitive(s))")
    if mask_path:
        stats = write_clip_mask(mask_path, builder, plan)
        if "skipped" in stats:
            print(f"  clip mask skipped: {stats['skipped']}")
        else:
            print(f"  wrote {os.path.relpath(mask_path, REPO)} "
                  f"({stats['size']}, {stats['walkable_pixels']} walkable px)")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("plan", help="the floor plan JSON")
    parser.add_argument("--glb", help="output .glb (default: from the plan's `output`)")
    parser.add_argument("--mask", help="output clip mask PNG (default: from the plan's `output`)")
    parser.add_argument("--check", action="store_true", help="report only, write nothing")
    args = parser.parse_args()

    plan_path = args.plan if os.path.isabs(args.plan) else os.path.join(REPO, args.plan)
    with open(plan_path) as handle:
        output = json.load(handle).get("output", {})

    def resolve(explicit, key):
        value = explicit or output.get(key)
        if not value:
            return None
        return value if os.path.isabs(value) else os.path.join(REPO, value)

    try:
        build(plan_path, resolve(args.glb, "glb"), resolve(args.mask, "clip_mask"), args.check)
    except (KeyError, ValueError, FileNotFoundError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
