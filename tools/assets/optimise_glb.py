#!/usr/bin/env python3
"""Post-process a .glb the same three ways Extrude-Image now exports:

  - collapse materials that are identical by content
  - downscale any image whose longest edge exceeds a cap
  - weld vertices, which three.js's ExtrudeGeometry never shares

Plus one that is free here: the wall textures are RGBA but fully opaque, so the
alpha channel carries no information and is dropped.

Rebuilds accessors and buffer views from scratch, which is only safe because
these assets have no skins, animations, morph targets or sparse accessors --
asserted below, matching the check GLTFLoader.swift documents.
"""
import io
import json
import struct
import sys
from collections import OrderedDict

from PIL import Image

GLB_MAGIC = 0x46546C67
CHUNK_JSON = 0x4E4F534A
CHUNK_BIN = 0x004E4942

COMPONENT_FMT = {5120: 'b', 5121: 'B', 5122: 'h', 5123: 'H', 5125: 'I', 5126: 'f'}
TYPE_COUNT = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4, 'MAT4': 16}


def read_glb(path):
    data = open(path, 'rb').read()
    magic, _, _ = struct.unpack_from('<III', data, 0)
    assert magic == GLB_MAGIC, 'not a GLB'
    js = binary = None
    off = 12
    while off < len(data):
        clen, ctype = struct.unpack_from('<II', data, off)
        chunk = data[off + 8:off + 8 + clen]
        if ctype == CHUNK_JSON:
            js = json.loads(chunk.decode('utf-8'))
        elif ctype == CHUNK_BIN:
            binary = chunk
        off += 8 + clen + ((-clen) % 4)
    return js, binary


def write_glb(path, js, binary):
    js_bytes = json.dumps(js, separators=(',', ':')).encode('utf-8')
    js_bytes += b' ' * ((-len(js_bytes)) % 4)
    binary += b'\x00' * ((-len(binary)) % 4)
    total = 12 + 8 + len(js_bytes) + 8 + len(binary)
    with open(path, 'wb') as f:
        f.write(struct.pack('<III', GLB_MAGIC, 2, total))
        f.write(struct.pack('<II', len(js_bytes), CHUNK_JSON))
        f.write(js_bytes)
        f.write(struct.pack('<II', len(binary), CHUNK_BIN))
        f.write(binary)


def view_bytes(js, binary, index):
    bv = js['bufferViews'][index]
    off = bv.get('byteOffset', 0)
    return binary[off:off + bv['byteLength']]


def read_accessor(js, binary, index):
    """Returns a list of per-element tuples. Rejects the cases this tool cannot rebuild."""
    acc = js['accessors'][index]
    assert 'sparse' not in acc, 'sparse accessors are not supported'
    n = TYPE_COUNT[acc['type']]
    fmt = COMPONENT_FMT[acc['componentType']]
    size = struct.calcsize('<' + fmt)
    bv = js['bufferViews'][acc['bufferView']]
    base = bv.get('byteOffset', 0) + acc.get('byteOffset', 0)
    stride = bv.get('byteStride') or (n * size)
    out = []
    for i in range(acc['count']):
        out.append(struct.unpack_from('<%d%s' % (n, fmt), binary, base + i * stride))
    return out


class BufferBuilder:
    def __init__(self):
        self.parts = []
        self.length = 0

    def add(self, raw, target=None, stride=None):
        pad = (-self.length) % 4
        if pad:
            self.parts.append(b'\x00' * pad)
            self.length += pad
        offset = self.length
        self.parts.append(raw)
        self.length += len(raw)
        view = {'buffer': 0, 'byteOffset': offset, 'byteLength': len(raw)}
        if target is not None:
            view['target'] = target
        if stride is not None:
            view['byteStride'] = stride
        return view

    def data(self):
        return b''.join(self.parts)


def optimise(src, dst, max_texture=2048):
    js, binary = read_glb(src)

    assert not js.get('skins'), 'skinned models are not supported'
    assert not js.get('animations'), 'animated models are not supported'
    for mesh in js['meshes']:
        for prim in mesh['primitives']:
            assert 'targets' not in prim, 'morph targets are not supported'
            assert prim.get('mode', 4) == 4, 'only triangle primitives are supported'

    report = {}

    # ---- images: downscale over the cap, drop alpha where it is fully opaque ----
    new_images = []
    image_stats = []
    for img_def in js.get('images', []):
        raw = view_bytes(js, binary, img_def['bufferView'])
        before = len(raw)
        img = Image.open(io.BytesIO(raw))
        w0, h0 = img.size
        mode0 = img.mode

        resized = False
        if max(img.size) > max_texture:
            scale = max_texture / max(img.size)
            img = img.resize((max(1, round(img.width * scale)), max(1, round(img.height * scale))),
                             Image.LANCZOS)
            resized = True

        dropped_alpha = False
        if img.mode in ('RGBA', 'LA', 'PA') or 'transparency' in img.info:
            rgba = img.convert('RGBA')
            if rgba.getchannel('A').getextrema()[0] == 255:
                img = rgba.convert('RGB')
                dropped_alpha = True
            else:
                img = rgba

        out = io.BytesIO()
        img.save(out, format='PNG', optimize=True)
        raw = out.getvalue()

        new_images.append(raw)
        image_stats.append({
            'from': f'{w0}x{h0} {mode0}', 'to': f'{img.width}x{img.height} {img.mode}',
            'mb_before': before / 1048576, 'mb_after': len(raw) / 1048576,
            'resized': resized, 'dropped_alpha': dropped_alpha,
        })
    report['images'] = image_stats

    # ---- materials: collapse the ones that are identical by content ----
    materials = js.get('materials', [])
    canonical = OrderedDict()
    material_remap = {}
    for i, mat in enumerate(materials):
        key = json.dumps(mat, sort_keys=True)
        if key not in canonical:
            canonical[key] = len(canonical)
        material_remap[i] = canonical[key]
    new_materials = [json.loads(k) for k in canonical]
    report['materials'] = {'before': len(materials), 'after': len(new_materials)}

    # ---- geometry: weld per group of primitives that share an attribute set ----
    builder = BufferBuilder()
    new_views = []
    new_accessors = []

    def add_accessor(view, count, type_, component_type, minmax=None):
        new_views.append(view)
        acc = {'bufferView': len(new_views) - 1, 'componentType': component_type,
               'count': count, 'type': type_}
        if minmax:
            acc['min'], acc['max'] = minmax
        new_accessors.append(acc)
        return len(new_accessors) - 1

    verts_before = verts_after = tris = 0
    new_meshes = []
    for mesh in js['meshes']:
        groups = OrderedDict()
        for prim in mesh['primitives']:
            groups.setdefault(tuple(sorted(prim['attributes'].items())), []).append(prim)

        out_prims = []
        for attr_key, prims in groups.items():
            names = [n for n, _ in attr_key]
            columns = {n: read_accessor(js, binary, a) for n, a in attr_key}
            verts_before += len(columns[names[0]])

            unique = {}
            order = []
            remap = {}
            for prim in prims:
                for idx in [i[0] for i in read_accessor(js, binary, prim['indices'])]:
                    if idx in remap:
                        continue
                    signature = tuple(columns[n][idx] for n in names)
                    if signature not in unique:
                        unique[signature] = len(order)
                        order.append(idx)
                    remap[idx] = unique[signature]
            verts_after += len(order)

            attr_accessors = {}
            for name in names:
                col = columns[name]
                width = len(col[0])
                raw = b''.join(struct.pack('<%df' % width, *col[i]) for i in order)
                view = builder.add(raw, target=34962)
                minmax = None
                if name == 'POSITION':
                    cols = list(zip(*(col[i] for i in order)))
                    minmax = ([min(c) for c in cols], [max(c) for c in cols])
                attr_accessors[name] = add_accessor(
                    view, len(order), {2: 'VEC2', 3: 'VEC3', 4: 'VEC4'}[width], 5126, minmax)

            for prim in prims:
                idx = [remap[i[0]] for i in read_accessor(js, binary, prim['indices'])]
                tris += len(idx) // 3
                fmt, ctype = ('<%dH', 5123) if len(order) <= 65535 else ('<%dI', 5125)
                raw = struct.pack(fmt % len(idx), *idx)
                view = builder.add(raw, target=34963)
                out = {'attributes': dict(attr_accessors),
                       'indices': add_accessor(view, len(idx), 'SCALAR', ctype)}
                if 'material' in prim:
                    out['material'] = material_remap[prim['material']]
                out_prims.append(out)

        new_mesh = {'primitives': out_prims}
        if 'name' in mesh:
            new_mesh['name'] = mesh['name']
        new_meshes.append(new_mesh)

    report['vertices'] = {'before': verts_before, 'after': verts_after, 'triangles': tris}

    # Images go in last so the vertex data stays tightly packed.
    image_defs = []
    for raw in new_images:
        new_views.append(builder.add(raw))
        image_defs.append({'bufferView': len(new_views) - 1, 'mimeType': 'image/png'})

    out = dict(js)
    out['bufferViews'] = new_views
    out['accessors'] = new_accessors
    out['meshes'] = new_meshes
    out['materials'] = new_materials
    if image_defs:
        out['images'] = image_defs
    out['buffers'] = [{'byteLength': len(builder.data())}]
    out.setdefault('asset', {})['generator'] = (
        js.get('asset', {}).get('generator', '') + ' + optimise_glb.py').strip()

    write_glb(dst, out, builder.data())
    return report


if __name__ == '__main__':
    src, dst = sys.argv[1], sys.argv[2]
    cap = int(sys.argv[3]) if len(sys.argv) > 3 else 2048
    r = optimise(src, dst, cap)
    print(json.dumps(r, indent=1))
