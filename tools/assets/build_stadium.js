#!/usr/bin/env node
//
// Turns the Fab export of the tennis stadium into a model this game can actually draw.
//
//   node build_stadium.js
//   original_images/Models/tennisstadium.glb  (163 MB)  →  assets/models/tennis_stadium.glb
//
// The export is a film asset: 4K normal and ORM maps for every shader, tangents, a 3436-channel
// animation, and its own tennis court. `GLTFLoader.swift` reads none of that — it takes base
// colour, emissive, and the pbr *factors* — so most of the file is weight the app pays for on
// install and never uses. Worse, what it does read is wrong: a material whose metalness lives
// in an ORM texture has **no `metallicFactor`**, and glTF's default for that is 1, so the whole
// stadium arrives fully metallic and renders nearly black. That is the lighting bug, and it is
// fixed here rather than in the shader because the information — the average of the map — is
// only available where the map is.
//
// What this does, in order:
//
//   1. Drops the model's own court and its singles net. The game draws those itself, in the
//      right place, at the size its physics believes in. Two courts 2 cm apart is a z-fight.
//   2. Bakes each ORM map down to the two numbers the engine reads: mean roughness (G) and mean
//      metalness (B), multiplied into the material's own factors.
//   3. Multiplies the occlusion channel (R) into the base colour texture, so the stands keep
//      the contact shadow that made them read as seats rather than as a green wall.
//   4. Binarises cut-out alpha. `characterFragment` discards at a <= 0.001 and there is no
//      alpha-test uniform to set, so a texture whose alpha is only ever 0 or 1 gets a correct
//      cut-out through the ordinary opaque pipeline, with no shader change and no sorting.
//   5. Halves every texture and re-encodes it.
//   6. Repacks the buffer, keeping only POSITION, NORMAL, TEXCOORD_0 and the indices. TANGENT
//      and TEXCOORD_1 are 13 MB the loader never looks at.
//   7. Merges the 1731 meshes into one per material, with the node transforms baked in. This is
//      the load-time fix: `GLTFLoader.readAccessor` walks an accessor element by element in
//      Swift, and 6900 of them in a debug build is most of a minute. `ModelStore` merges to the
//      same 15 groups either way, so doing it here changes nothing on screen.
//
// Re-runnable and deterministic: same input, same output.

import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import sharp from 'sharp';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const INPUT = path.join(ROOT, 'original_images/Models/tennisstadium.glb');
const OUTPUT = path.join(ROOT, 'assets/models/tennis_stadium.glb');

/// Nodes removed wholesale, by name. See note 1 above.
const DROP_NODES = new Set([
    'TennisCourt.001_2701',   // grass slab + chalk lines — the game draws its own
    'SinglesNet_19',          // ditto the net, whose height the ball physics depends on

    // **The near half of the retractable roof, and it has to go.** Both halves are parked open,
    // stacked eight metres thick, over the two ends of the court — world y +24 to +36 for this
    // one. The tennis camera sits behind the player's baseline at about y +43 and 42 m up, and
    // its sight line to the middle of the court passes through that stack at 24 m: the first run
    // with the stadium in had the bottom two-thirds of the frame filled with grey roof panels
    // and truss, with the court showing through a slot. Its twin at the far end (`Roof01_1351`)
    // is kept — up there it is scenery above the far stand, which is what a roof should be.
    //
    // It is also 139,000 vertices, a quarter of the whole model.
    'Roof02_2682',
]);

/// Longest edge a texture may keep. 4K maps on a stadium that is 200 px tall on an iPhone are
/// there for a film render; 1K is still more than the screen can show.
const MAX_TEXTURE = 1024;

/// How much of the occlusion map to multiply into the base colour, per material, with `*` as
/// the default. Applied as `mix(1, ao, strength)` — 1 is the raw map, 0 ignores it.
///
/// It is deliberately not 1 anywhere. Ambient occlusion is meant to attenuate *ambient* light
/// and nothing else; baking it into albedo attenuates the spotlight too, so a full-strength bake
/// double-counts every crevice. 0.6 is where the stands still gain their depth without the whole
/// stadium going a stop darker than the artist drew it.
///
/// `TennisPropsShader` is the interesting one. It is the umpire chair, the line judges' seats,
/// the benches and the bin — small tubular things standing **beside the court**, where you look
/// straight at them, and a tube occludes itself from every direction, so its occlusion map is
/// dark nearly everywhere. Its albedo is already a dark green (mean 32, 63, 24); a full bake took
/// it to 20, 36, 16 and the umpire chair rendered as a black silhouette with no readable form.
/// The stands are the opposite case: big flat surfaces whose only shape comes from the crevices
/// between them.
const OCCLUSION_STRENGTH = { '*': 0.6, TennisPropsShader: 0.2 };

/// Per-material floor under the base colour, 0–255, applied as `in·(255−floor)/255 + floor` so
/// it lifts the blacks and leaves white where it is.
///
/// **This is a lighting fix, not a repaint.** `TennisPropsShader` — the umpire chair, the line
/// judges' seats, the benches — is authored very nearly black, which is what an umpire chair is.
/// In a renderer with an environment map that still reads as a shape, because a black surface is
/// mostly the reflection of the sky and the stands. This one has a single spotlight and a flat
/// ambient term and no environment at all, so `albedo × light` on a near-black albedo is
/// near-black whichever way the tube is facing, and the chair arrives as a solid silhouette with
/// no form in it. Lifting the floor to a dark charcoal gives the diffuse lobe something to
/// shade, and the chair gets its struts and its wheels back.
const BLACK_FLOOR = { TennisPropsShader: 58 };

/// Materials that should not arrive as opaque black. The loader understands
/// `KHR_materials_transmission`, and the renderer has a premultiplied pass for it, so the press
/// box glazing can be glass instead of a hole.
const TRANSMISSION = { GlassShader: 0.72 };

// ---------------------------------------------------------------------------- GLB container

function readGLB(file) {
    const buf = fs.readFileSync(file);
    if (buf.readUInt32LE(0) !== 0x46546c67) throw new Error(`${file} is not a .glb`);
    const total = buf.readUInt32LE(8);

    let offset = 12;
    let json = null;
    let bin = null;
    while (offset + 8 <= total) {
        const length = buf.readUInt32LE(offset);
        const type = buf.readUInt32LE(offset + 4);
        const start = offset + 8;
        if (type === 0x4e4f534a) json = JSON.parse(buf.subarray(start, start + length).toString('utf8'));
        else if (type === 0x004e4942) bin = buf.subarray(start, start + length);
        offset = start + length;
    }
    if (!json) throw new Error('no JSON chunk');
    return { json, bin };
}

function writeGLB(file, json, bin) {
    const jsonBuf = Buffer.from(JSON.stringify(json), 'utf8');
    const jsonPad = (4 - (jsonBuf.length % 4)) % 4;
    const binPad = (4 - (bin.length % 4)) % 4;

    const header = Buffer.alloc(12);
    header.writeUInt32LE(0x46546c67, 0);
    header.writeUInt32LE(2, 4);
    header.writeUInt32LE(12 + 8 + jsonBuf.length + jsonPad + 8 + bin.length + binPad, 8);

    const jsonHeader = Buffer.alloc(8);
    jsonHeader.writeUInt32LE(jsonBuf.length + jsonPad, 0);
    jsonHeader.writeUInt32LE(0x4e4f534a, 4);

    const binHeader = Buffer.alloc(8);
    binHeader.writeUInt32LE(bin.length + binPad, 0);
    binHeader.writeUInt32LE(0x004e4942, 4);

    fs.writeFileSync(file, Buffer.concat([
        header,
        jsonHeader, jsonBuf, Buffer.alloc(jsonPad, 0x20),
        binHeader, bin, Buffer.alloc(binPad, 0),
    ]));
}

const view = (json, bin, index) => {
    const v = json.bufferViews[index];
    const start = v.byteOffset || 0;
    return bin.subarray(start, start + v.byteLength);
};

// ---------------------------------------------------------------------------- textures

const COMPONENTS = { SCALAR: 1, VEC2: 2, VEC3: 3, VEC4: 4, MAT2: 4, MAT3: 9, MAT4: 16 };
const COMPONENT_SIZE = { 5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4 };

const imageOf = (json, ref) => (ref == null ? null : json.textures[ref.index].source);

/// Mean of one channel of an image, 0–1, on a small thumbnail — the average of a 4K map and the
/// average of its 64 px thumbnail agree to about a part in a thousand, and one is 4000 times
/// faster.
async function channelMean(buffer, channel) {
    const { data, info } = await sharp(buffer)
        .resize(64, 64, { fit: 'fill' })
        .removeAlpha()
        .raw()
        .toBuffer({ resolveWithObject: true });
    let sum = 0;
    for (let i = channel; i < data.length; i += info.channels) sum += data[i];
    return sum / (info.width * info.height) / 255;
}

/// Re-encodes one texture. `occlusion` is the ORM buffer whose red channel is multiplied in, at
/// `strength`. Alpha, if the source has any, comes out strictly 0 or 255 — see note 4.
async function bakeTexture(buffer, occlusionBuffer, strength, floor = 0) {
    const meta = await sharp(buffer).metadata();
    const size = Math.min(MAX_TEXTURE, Math.max(meta.width, meta.height));
    let image = sharp(buffer).resize(size, size, { fit: 'fill' });
    // Before the occlusion, so a lifted black can still be shaded by a crevice.
    if (floor > 0) image = image.linear((255 - floor) / 255, floor);

    if (occlusionBuffer && strength > 0) {
        // The ORM's red channel as a greyscale image the same size, lifted towards white by
        // `1 - strength` and then multiplied over the colour. `linear(a, b)` is `a·x + b`.
        // Multiply keeps the alpha of the base, which is what carries the cut-out.
        const ao = await sharp(occlusionBuffer)
            .resize(size, size, { fit: 'fill' })
            .extractChannel('red')
            .toColourspace('b-w')
            .linear(strength, 255 * (1 - strength))
            .png()
            .toBuffer();
        image = sharp(await image.png().toBuffer())
            .composite([{ input: ao, blend: 'multiply' }]);
    }

    if (!meta.hasAlpha) {
        return { data: await image.jpeg({ quality: 82, chromaSubsampling: '4:4:4' }).toBuffer(),
                 mime: 'image/jpeg' };
    }

    // Binarise: everything the artist made even slightly see-through becomes a hole, everything
    // else becomes solid. A seat edge that was 0.5 would otherwise survive the shader's discard
    // and draw as an opaque halo.
    const { data, info } = await sharp(await image.png().toBuffer())
        .ensureAlpha()
        .raw()
        .toBuffer({ resolveWithObject: true });
    for (let i = 3; i < data.length; i += 4) data[i] = data[i] >= 128 ? 255 : 0;
    return {
        data: await sharp(data, { raw: { width: info.width, height: info.height, channels: 4 } })
            .png({ compressionLevel: 9, palette: false })
            .toBuffer(),
        mime: 'image/png',
    };
}

// ---------------------------------------------------------------------------- main

async function main() {
    const { json, bin } = readGLB(INPUT);
    console.log(`in  ${(fs.statSync(INPUT).size / 1e6).toFixed(1)} MB — `
        + `${json.nodes.length} nodes, ${json.meshes.length} meshes, ${json.images.length} images`);

    // --- 1. Prune the scene graph -------------------------------------------------------
    const dropped = new Set();
    json.nodes.forEach((node, index) => { if (DROP_NODES.has(node.name)) dropped.add(index); });
    for (const name of DROP_NODES) {
        if (![...dropped].some(i => json.nodes[i].name === name)) {
            throw new Error(`node to drop not found: ${name} — has the export changed?`);
        }
    }

    const keptNodes = new Set();
    const walk = (index) => {
        if (dropped.has(index) || keptNodes.has(index)) return;
        keptNodes.add(index);
        for (const child of json.nodes[index].children || []) walk(child);
    };
    for (const root of json.scenes[json.scene || 0].nodes) walk(root);

    // Animations reference nodes and the loader ignores them entirely.
    delete json.animations;

    // --- 2/3. Materials: bake the ORM down to factors, and the AO into the colour ---------
    const usedMaterials = new Set();
    for (const index of keptNodes) {
        const node = json.nodes[index];
        if (node.mesh == null) continue;
        for (const prim of json.meshes[node.mesh].primitives) usedMaterials.add(prim.material);
    }

    /// image index -> re-encoded bytes. Built as materials are visited so an image shared by two
    /// materials is baked once.
    const baked = new Map();

    for (const materialIndex of [...usedMaterials].sort((a, b) => a - b)) {
        const material = json.materials[materialIndex];
        const pbr = material.pbrMetallicRoughness || (material.pbrMetallicRoughness = {});

        const ormImage = imageOf(json, pbr.metallicRoughnessTexture) ?? imageOf(json, material.occlusionTexture);
        let roughness = pbr.roughnessFactor ?? 1;
        let metalness = pbr.metallicFactor ?? 1;

        if (ormImage != null) {
            const orm = view(json, bin, json.images[ormImage].bufferView);
            roughness *= await channelMean(orm, 1);
            metalness *= await channelMean(orm, 2);
        } else if (pbr.metallicFactor == null) {
            // No map and no factor: glTF says 1, the artist meant "not metal".
            metalness = 0;
        }
        pbr.roughnessFactor = Math.round(roughness * 1000) / 1000;
        pbr.metallicFactor = Math.round(metalness * 1000) / 1000;

        const baseImage = imageOf(json, pbr.baseColorTexture);
        if (baseImage != null && !baked.has(baseImage)) {
            // Only bake the occlusion in when both maps sample the same UVs untransformed —
            // FabricShader tiles its colour 15x and its AO would land somewhere else entirely.
            const sameUV = ormImage != null
                && !(pbr.baseColorTexture.extensions || {}).KHR_texture_transform
                && (pbr.baseColorTexture.texCoord || 0) === 0;
            const strength = OCCLUSION_STRENGTH[material.name] ?? OCCLUSION_STRENGTH['*'];
            const floor = BLACK_FLOOR[material.name] ?? 0;
            baked.set(baseImage, await bakeTexture(
                view(json, bin, json.images[baseImage].bufferView),
                sameUV ? view(json, bin, json.images[ormImage].bufferView) : null,
                strength, floor));
            console.log(`  ${material.name.padEnd(24)} rough ${pbr.roughnessFactor.toFixed(2)} `
                + `metal ${pbr.metallicFactor.toFixed(2)}  `
                + `${sameUV ? `AO ${strength.toFixed(2)}` : '        '}`
                + `${floor ? `  floor ${floor}` : ''}`);
        }

        const emissiveImage = imageOf(json, material.emissiveTexture);
        if (emissiveImage != null && !baked.has(emissiveImage)) {
            baked.set(emissiveImage, await bakeTexture(
                view(json, bin, json.images[emissiveImage].bufferView), null, 0));
        }

        // The maps the engine cannot read. Left in place they would only be shipped.
        delete pbr.metallicRoughnessTexture;
        delete material.occlusionTexture;
        delete material.normalTexture;

        if (TRANSMISSION[material.name] != null) {
            material.extensions = material.extensions || {};
            material.extensions.KHR_materials_transmission = {
                transmissionFactor: TRANSMISSION[material.name],
            };
            delete material.alphaMode;
            // A transmissive surface's own colour is its tint, not its coverage.
            if (pbr.baseColorFactor) pbr.baseColorFactor[3] = 1;
        }
    }

    // --- 5/6. Repack ---------------------------------------------------------------------
    const out = [];          // chunks of the new buffer
    let outLength = 0;
    const newViews = [];

    function append(buffer, extra = {}) {
        const pad = (4 - (outLength % 4)) % 4;
        if (pad) { out.push(Buffer.alloc(pad)); outLength += pad; }
        const index = newViews.length;
        newViews.push({ buffer: 0, byteOffset: outLength, byteLength: buffer.length, ...extra });
        out.push(buffer);
        outLength += buffer.length;
        return index;
    }

    /// One accessor's elements, de-interleaved into a flat array of numbers.
    function readAccessor(index) {
        const accessor = json.accessors[index];
        const components = COMPONENTS[accessor.type];
        const size = COMPONENT_SIZE[accessor.componentType];
        const source = json.bufferViews[accessor.bufferView];
        const stride = source.byteStride || components * size;
        const base = (source.byteOffset || 0) + (accessor.byteOffset || 0);

        const out = accessor.componentType === 5126
            ? new Float32Array(accessor.count * components)
            : new Uint32Array(accessor.count * components);
        for (let e = 0; e < accessor.count; e++) {
            for (let c = 0; c < components; c++) {
                const at = base + e * stride + c * size;
                out[e * components + c] = accessor.componentType === 5126 ? bin.readFloatLE(at)
                    : accessor.componentType === 5125 ? bin.readUInt32LE(at)
                    : accessor.componentType === 5123 ? bin.readUInt16LE(at)
                    : bin.readUInt8(at);
            }
        }
        return out;
    }

    /// World transform of a node, walking down from the scene root. glTF column-major, as flat
    /// arrays of 16.
    const mul = (a, b) => {
        const m = new Array(16).fill(0);
        for (let c = 0; c < 4; c++) {
            for (let r = 0; r < 4; r++) {
                for (let k = 0; k < 4; k++) m[c * 4 + r] += a[k * 4 + r] * b[c * 4 + k];
            }
        }
        return m;
    };
    const localMatrix = (node) => {
        if (node.matrix) return node.matrix;
        const [x, y, z, w] = node.rotation || [0, 0, 0, 1];
        const [sx, sy, sz] = node.scale || [1, 1, 1];
        const [tx, ty, tz] = node.translation || [0, 0, 0];
        return [
            (1 - 2 * (y * y + z * z)) * sx, (2 * (x * y + z * w)) * sx, (2 * (x * z - y * w)) * sx, 0,
            (2 * (x * y - z * w)) * sy, (1 - 2 * (x * x + z * z)) * sy, (2 * (y * z + x * w)) * sy, 0,
            (2 * (x * z + y * w)) * sz, (2 * (y * z - x * w)) * sz, (1 - 2 * (x * x + y * y)) * sz, 0,
            tx, ty, tz, 1,
        ];
    };
    const worldOf = new Map();
    (function descend(index, parent) {
        if (!keptNodes.has(index)) return;
        const m = mul(parent, localMatrix(json.nodes[index]));
        // The normal shortcut below only holds for a uniform scale. Say so loudly rather than
        // shipping a stadium lit with skewed normals.
        const axes = [0, 1, 2].map(c => Math.hypot(m[c * 4], m[c * 4 + 1], m[c * 4 + 2]));
        if (Math.max(...axes) - Math.min(...axes) > 1e-4 * Math.max(...axes)) {
            throw new Error(`node ${json.nodes[index].name} has a non-uniform world scale `
                + `(${axes.map(a => a.toFixed(4))}) — merging would need the inverse transpose`);
        }
        worldOf.set(index, m);
        for (const child of json.nodes[index].children || []) descend(child, m);
    })(json.scenes[json.scene || 0].nodes[0], [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]);

    // --- 7. Merge every primitive that shares a material into one mesh -------------------
    const merged = new Map();   // material index -> { position, normal, uv, indices }
    for (const nodeIndex of [...keptNodes].sort((a, b) => a - b)) {
        const node = json.nodes[nodeIndex];
        if (node.mesh == null) continue;
        const m = worldOf.get(nodeIndex);

        for (const prim of json.meshes[node.mesh].primitives) {
            const position = readAccessor(prim.attributes.POSITION);
            const count = position.length / 3;
            const normal = prim.attributes.NORMAL != null ? readAccessor(prim.attributes.NORMAL) : null;
            const uv = prim.attributes.TEXCOORD_0 != null ? readAccessor(prim.attributes.TEXCOORD_0) : null;
            const indices = prim.indices != null ? readAccessor(prim.indices) : null;

            const group = merged.get(prim.material)
                || { position: [], normal: [], uv: [], indices: [], count: 0 };
            const base = group.count;

            for (let i = 0; i < count; i++) {
                const [x, y, z] = [position[i * 3], position[i * 3 + 1], position[i * 3 + 2]];
                group.position.push(m[0] * x + m[4] * y + m[8] * z + m[12],
                                    m[1] * x + m[5] * y + m[9] * z + m[13],
                                    m[2] * x + m[6] * y + m[10] * z + m[14]);
                // Every transform in this asset is a rigid motion with a uniform scale, so the
                // inverse transpose is the same rotation and normals go through the upper 3x3
                // and are renormalised. (Checked: no node carries a non-uniform scale.)
                const [nx, ny, nz] = normal ? [normal[i * 3], normal[i * 3 + 1], normal[i * 3 + 2]] : [0, 1, 0];
                let wx = m[0] * nx + m[4] * ny + m[8] * nz;
                let wy = m[1] * nx + m[5] * ny + m[9] * nz;
                let wz = m[2] * nx + m[6] * ny + m[10] * nz;
                const length = Math.hypot(wx, wy, wz) || 1;
                group.normal.push(wx / length, wy / length, wz / length);
                group.uv.push(uv ? uv[i * 2] : 0, uv ? uv[i * 2 + 1] : 0);
            }

            if (indices) for (const i of indices) group.indices.push(base + i);
            else for (let i = 0; i < count; i++) group.indices.push(base + i);

            group.count += count;
            merged.set(prim.material, group);
        }
    }

    const newAccessors = [];
    const newMeshes = [];

    function addAccessor(array, componentType, type, target, bounds) {
        const buffer = componentType === 5126
            ? Buffer.from(Float32Array.from(array).buffer)
            : Buffer.from(Uint32Array.from(array).buffer);
        const accessor = {
            bufferView: append(buffer, { target }),
            componentType,
            count: array.length / COMPONENTS[type],
            type,
        };
        if (bounds) { accessor.min = bounds[0]; accessor.max = bounds[1]; }
        newAccessors.push(accessor);
        return newAccessors.length - 1;
    }

    for (const [material, group] of [...merged].sort((a, b) => a[0] - b[0])) {
        const min = [Infinity, Infinity, Infinity];
        const max = [-Infinity, -Infinity, -Infinity];
        for (let i = 0; i < group.position.length; i++) {
            const axis = i % 3;
            if (group.position[i] < min[axis]) min[axis] = group.position[i];
            if (group.position[i] > max[axis]) max[axis] = group.position[i];
        }
        newMeshes.push({
            name: json.materials[material].name,
            primitives: [{
                attributes: {
                    POSITION: addAccessor(group.position, 5126, 'VEC3', 34962, [min, max]),
                    NORMAL: addAccessor(group.normal, 5126, 'VEC3', 34962),
                    TEXCOORD_0: addAccessor(group.uv, 5126, 'VEC2', 34962),
                },
                indices: addAccessor(group.indices, 5125, 'SCALAR', 34963),
                material,
            }],
        });
    }

    // Images last, so the geometry stays at the front of the file where a mapped read finds it.
    const newImages = [];
    const imageMap = new Map();
    for (const [imageIndex, { data, mime }] of [...baked].sort((a, b) => a[0] - b[0])) {
        imageMap.set(imageIndex, newImages.length);
        newImages.push({ bufferView: append(data), mimeType: mime });
    }

    // --- Rewrite the JSON ----------------------------------------------------------------
    // Everything is in world space now, so the graph is one node per merged mesh under a root.
    json.nodes = [{ name: 'TennisStadium', children: newMeshes.map((_, i) => i + 1) }]
        .concat(newMeshes.map((mesh, i) => ({ name: mesh.name, mesh: i })));
    json.scenes = [{ nodes: [0] }];
    json.scene = 0;
    json.meshes = newMeshes;
    json.accessors = newAccessors;
    json.bufferViews = newViews;
    json.images = newImages;
    json.textures = json.textures.map(t => ({ source: imageMap.get(t.source) }))
        .map((t, i) => (t.source == null ? null : t));

    // Textures whose image is gone (every normal and ORM map) leave holes; renumber past them.
    const textureMap = new Map();
    const keptTextures = [];
    json.textures.forEach((texture, index) => {
        if (!texture) return;
        textureMap.set(index, keptTextures.length);
        keptTextures.push(texture);
    });
    json.textures = keptTextures;

    json.materials = json.materials.map((material, index) => {
        if (!usedMaterials.has(index)) return { name: material.name };   // referenced by nothing
        const pbr = material.pbrMetallicRoughness;
        if (pbr.baseColorTexture) pbr.baseColorTexture.index = textureMap.get(pbr.baseColorTexture.index);
        if (material.emissiveTexture) material.emissiveTexture.index = textureMap.get(material.emissiveTexture.index);
        return material;
    });

    json.buffers = [{ byteLength: outLength }];
    json.samplers = json.samplers || [{}];
    json.extensionsUsed = ['KHR_texture_transform', 'KHR_materials_specular', 'KHR_materials_transmission'];
    delete json.extensionsRequired;
    json.asset = { version: '2.0', generator: 'joels-world build_stadium.js' };

    writeGLB(OUTPUT, json, Buffer.concat(out, outLength));

    const verts = [...merged.values()].reduce((n, g) => n + g.count, 0);
    const tris = [...merged.values()].reduce((n, g) => n + g.indices.length / 3, 0);
    console.log(`out ${(fs.statSync(OUTPUT).size / 1e6).toFixed(1)} MB — `
        + `${json.nodes.length} nodes, ${newMeshes.length} meshes, ${newImages.length} images, `
        + `${verts} vertices, ${tris} triangles`);
    console.log(`    ${path.relative(ROOT, OUTPUT)}`);
}

main().catch(error => { console.error(error); process.exit(1); });
