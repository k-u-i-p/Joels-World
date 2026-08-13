#!/usr/bin/env python3
"""Split assets/models/rocks/rocks.glb into one GLB per rock.

The bought pack ships all 11 rocks in a single file, laid out in a row and
sharing one 4096x4096 texture atlas. This pulls each rock out into its own
GLB, with:

  - the parent transform chain baked in (so it comes out Y-up, metres, and
    the right way round with no wrapper nodes),
  - the rock recentred on the origin with its base sitting on Y=0,
  - the shared atlas resampled down (the UVs of every rock cover most of the
    atlas, so it can't be cropped per rock - only shrunk).

Usage:  python3 tools/assets/split_rocks.py [--size 1024]
"""

import argparse
import io
import json
import struct
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "assets/models/rocks/rocks.glb"
OUT_DIR = ROOT / "assets/models/rocks"

COMPONENT = {5126: ("f", 4), 5123: ("H", 2), 5125: ("I", 4)}
NCOMP = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}


# --- tiny 4x4 matrix helpers (glTF matrices are column-major) ---------------

def mat_from_gltf(m):
    """[col0, col1, col2, col3] flat -> row-major list of rows."""
    return [[m[0], m[4], m[8], m[12]],
            [m[1], m[5], m[9], m[13]],
            [m[2], m[6], m[10], m[14]],
            [m[3], m[7], m[11], m[15]]]


IDENTITY = [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]]


def mat_mul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(4)) for j in range(4)]
            for i in range(4)]


def xform_point(m, p):
    x, y, z = p
    return (m[0][0] * x + m[0][1] * y + m[0][2] * z + m[0][3],
            m[1][0] * x + m[1][1] * y + m[1][2] * z + m[1][3],
            m[2][0] * x + m[2][1] * y + m[2][2] * z + m[2][3])


def xform_dir(m, v):
    x, y, z = v
    return (m[0][0] * x + m[0][1] * y + m[0][2] * z,
            m[1][0] * x + m[1][1] * y + m[1][2] * z,
            m[2][0] * x + m[2][1] * y + m[2][2] * z)


def normalise(v):
    n = (v[0] ** 2 + v[1] ** 2 + v[2] ** 2) ** 0.5
    return (v[0] / n, v[1] / n, v[2] / n) if n > 1e-12 else (0.0, 1.0, 0.0)


def node_matrix(node):
    if "matrix" in node:
        return mat_from_gltf(node["matrix"])
    m = IDENTITY
    if "translation" in node:
        t = node["translation"]
        m = mat_mul(m, [[1, 0, 0, t[0]], [0, 1, 0, t[1]], [0, 0, 1, t[2]], [0, 0, 0, 1]])
    if "rotation" in node:
        x, y, z, w = node["rotation"]
        r = [[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w), 0],
             [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w), 0],
             [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y), 0],
             [0, 0, 0, 1]]
        m = mat_mul(m, r)
    if "scale" in node:
        s = node["scale"]
        m = mat_mul(m, [[s[0], 0, 0, 0], [0, s[1], 0, 0], [0, 0, s[2], 0], [0, 0, 0, 1]])
    return m


# --- GLB reading ------------------------------------------------------------

def read_glb(path):
    data = path.read_bytes()
    magic, version, total = struct.unpack("<III", data[:12])
    assert magic == 0x46546C67 and version == 2, "not a glTF 2.0 binary"
    off, gltf, blob = 12, None, b""
    while off < total:
        clen, ctype = struct.unpack("<II", data[off:off + 8])
        chunk = data[off + 8:off + 8 + clen]
        if ctype == 0x4E4F534A:
            gltf = json.loads(chunk.decode("utf-8"))
        elif ctype == 0x004E4942:
            blob = chunk
        off += 8 + clen + (-clen % 4)
    return gltf, blob


def read_accessor(gltf, blob, index):
    acc = gltf["accessors"][index]
    bv = gltf["bufferViews"][acc["bufferView"]]
    fmt, size = COMPONENT[acc["componentType"]]
    n = NCOMP[acc["type"]]
    stride = bv.get("byteStride") or size * n
    base = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
    return [struct.unpack_from("<" + fmt * n, blob, base + i * stride)
            for i in range(acc["count"])]


# --- GLB writing ------------------------------------------------------------

def pad4(b, filler=b"\0"):
    return b + filler * (-len(b) % 4)


def write_glb(path, gltf, blob):
    gltf["buffers"] = [{"byteLength": len(blob)}]
    js = pad4(json.dumps(gltf, separators=(",", ":")).encode("utf-8"), b" ")
    bn = pad4(blob)
    total = 12 + 8 + len(js) + 8 + len(bn)
    with open(path, "wb") as f:
        f.write(struct.pack("<III", 0x46546C67, 2, total))
        f.write(struct.pack("<II", len(js), 0x4E4F534A))
        f.write(js)
        f.write(struct.pack("<II", len(bn), 0x004E4942))
        f.write(bn)
    return total


def build_rock(name, positions, normals, uvs, indices, png, material):
    """One mesh, one node, one material, one texture -> a complete GLB dict."""
    idx_fmt, idx_ctype = ("H", 5123) if len(positions) < 65536 else ("I", 5125)

    chunks, views, offset = [], [], 0

    def add_view(payload, **extra):
        nonlocal offset
        payload = pad4(payload)
        views.append(dict(buffer=0, byteOffset=offset, byteLength=len(payload), **extra))
        chunks.append(payload)
        offset += len(payload)
        return len(views) - 1

    idx_view = add_view(b"".join(struct.pack("<" + idx_fmt, i) for i in indices),
                        target=34963)
    pos_view = add_view(b"".join(struct.pack("<3f", *p) for p in positions),
                        byteStride=12, target=34962)
    nrm_view = add_view(b"".join(struct.pack("<3f", *n) for n in normals),
                        byteStride=12, target=34962)
    uv_view = add_view(b"".join(struct.pack("<2f", *t) for t in uvs),
                       byteStride=8, target=34962)
    img_view = add_view(png, name="RocksStylized_M_baseColor.png")

    def bounds(vals, n):
        return ([min(v[i] for v in vals) for i in range(n)],
                [max(v[i] for v in vals) for i in range(n)])

    pmin, pmax = bounds(positions, 3)
    accessors = [
        dict(bufferView=pos_view, componentType=5126, count=len(positions),
             type="VEC3", min=pmin, max=pmax),
        dict(bufferView=nrm_view, componentType=5126, count=len(normals), type="VEC3"),
        dict(bufferView=uv_view, componentType=5126, count=len(uvs), type="VEC2"),
        dict(bufferView=idx_view, componentType=idx_ctype, count=len(indices),
             type="SCALAR"),
    ]

    gltf = {
        "asset": {"version": "2.0",
                  "generator": "tools/assets/split_rocks.py (from rocks.glb)"},
        "extensionsUsed": ["KHR_materials_specular"],
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"name": name, "mesh": 0}],
        "meshes": [{"name": name, "primitives": [{
            "attributes": {"POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2},
            "indices": 3, "material": 0, "mode": 4}]}],
        "materials": [material],
        "textures": [{"sampler": 0, "source": 0}],
        "images": [{"bufferView": img_view, "mimeType": "image/png"}],
        "samplers": [{"magFilter": 9729, "minFilter": 9987,
                      "wrapS": 10497, "wrapT": 10497}],
        "accessors": accessors,
        "bufferViews": views,
    }
    return gltf, b"".join(chunks)


# --- main -------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--size", type=int, default=1024,
                    help="resample the shared atlas to this square size (0 = keep)")
    args = ap.parse_args()

    gltf, blob = read_glb(SRC)

    # The atlas, shrunk once and reused by every rock.
    src_view = gltf["bufferViews"][gltf["images"][0]["bufferView"]]
    raw = blob[src_view.get("byteOffset", 0):
               src_view.get("byteOffset", 0) + src_view["byteLength"]]
    if args.size:
        img = Image.open(io.BytesIO(raw)).convert("RGB")
        img = img.resize((args.size, args.size), Image.LANCZOS)
        buf = io.BytesIO()
        img.save(buf, format="PNG", optimize=True)
        png = buf.getvalue()
        print(f"atlas {Image.open(io.BytesIO(raw)).size[0]}px "
              f"{len(raw)/1e6:.1f} MB -> {args.size}px {len(png)/1e6:.1f} MB")
    else:
        png = raw

    material = json.loads(json.dumps(gltf["materials"][0]))

    # Walk the scene, carrying the accumulated transform down to each mesh.
    found = []

    def walk(node_index, parent):
        node = gltf["nodes"][node_index]
        world = mat_mul(parent, node_matrix(node))
        if "mesh" in node:
            found.append((node, world))
        for child in node.get("children", []):
            walk(child, world)

    for root in gltf["scenes"][gltf.get("scene", 0)]["nodes"]:
        walk(root, IDENTITY)

    for node, world in found:
        mesh = gltf["meshes"][node["mesh"]]
        prim = mesh["primitives"][0]
        positions = [xform_point(world, p)
                     for p in read_accessor(gltf, blob, prim["attributes"]["POSITION"])]
        normals = [normalise(xform_dir(world, n))
                   for n in read_accessor(gltf, blob, prim["attributes"]["NORMAL"])]
        uvs = read_accessor(gltf, blob, prim["attributes"]["TEXCOORD_0"])
        indices = [i[0] for i in read_accessor(gltf, blob, prim["indices"])]

        # Recentre: origin under the middle of the rock, base on the ground.
        cx = (min(p[0] for p in positions) + max(p[0] for p in positions)) / 2
        cz = (min(p[2] for p in positions) + max(p[2] for p in positions)) / 2
        fy = min(p[1] for p in positions)
        positions = [(p[0] - cx, p[1] - fy, p[2] - cz) for p in positions]

        # SM_Rocks_04_RocksStylized_M_0 -> rock_04
        stem = mesh["name"].split("_RocksStylized")[0]          # SM_Rocks_04
        out_name = "rock_" + stem.rsplit("_", 1)[-1]            # rock_04
        out_gltf, out_blob = build_rock(stem, positions, normals, uvs, indices,
                                        png, material)
        path = OUT_DIR / f"{out_name}.glb"
        size = write_glb(path, out_gltf, out_blob)
        w = max(p[0] for p in positions) - min(p[0] for p in positions)
        h = max(p[1] for p in positions)
        d = max(p[2] for p in positions) - min(p[2] for p in positions)
        print(f"{path.name:14s} {len(positions):5d} verts  {len(indices)//3:5d} tris  "
              f"{w:5.2f} x {h:5.2f} x {d:5.2f} m  {size/1e6:.2f} MB")


if __name__ == "__main__":
    main()
