#include <metal_stdlib>
using namespace metal;

constant float PI = 3.14159265358979323846;
constant float RECIPROCAL_PI = 1.0 / PI;

/// Colour slots in the skinned body's palette — skin, shirt, arm, pants. Must match
/// `SkinnedBody.paletteCount`.
constant uint SKIN_PALETTE_COUNT = 4;

// Vertices are indexed directly out of a device buffer, so no vertex descriptor is used.
struct QuadVertex {
    float3 position;
    float2 uv;
};

struct MeshVertex {
    float3 position;
    float3 normal;
    float2 uv;
};

/// A vertex of the skinned character body. Mirrors `SkinVertex` in `SkinnedBody.swift`.
///
/// `joints` indexes the matrix array bound at vertex buffer 2 and `colorSlot` the palette at
/// buffer 3 — the body is one draw call, so neither the bone nor the colour can come from the
/// uniforms any more. Both are floats: the eight bytes are cheaper than a layout mismatch
/// between Swift and Metal that nothing would report.
struct SkinVertex {
    float3 position;
    float3 normal;
    float4 weights;
    float4 joints;
    float2 uv;
    float  colorSlot;
    float  pad;
};

// MARK: - Shared per-pass state

/// Camera, lighting and shadow state, identical for every draw in a pass.
/// Mirrors `SceneUniforms` in `Lighting.swift`.
struct SceneUniforms {
    float4x4 view;
    float4x4 projection;
    float4x4 inverseProjection;
    float4x4 lightViewProjection;
    /// xyz = render-space camera position.
    float4   cameraPosition;
    /// xyz = render-space spotlight position.
    float4   lightPosition;
    /// xyz = unit vector pointing from the spot target *towards* the light, which is what
    /// three.js stores in `spotLight.direction`.
    float4   lightDirection;
    /// x = ambient intensity, y = spot intensity, z = cos(cone angle), w = cos(penumbra angle).
    float4   lightParams;
    /// x = 1 / shadow map size, y = depth bias, z = shadows enabled, w unused.
    float4   shadowParams;
    /// x = camera near, y = camera far, zw = viewport size in pixels.
    float4   cameraParams;
};

struct DrawUniforms {
    float4x4 modelViewProjection;
    float4x4 model;
    float4   tint;
    /// x = lit (ground layers) vs unlit (overlays), yzw unused.
    float4   flags;
};

struct CharacterUniforms {
    float4x4 modelViewProjection;
    float4x4 model;
    float4   color;
    /// xy = the character's world pivot, z = map width, w = map height.
    /// A zero map size disables the clip-mask march (used by props).
    float4   clipParams;
    /// x = sample the base-colour texture, y = unlit, z = roughness, w = metalness.
    float4   flags;
    /// xyz = emissive radiance (`emissiveFactor` × `KHR_materials_emissive_strength`),
    /// w = an emissive map is bound at texture 3.
    float4   emissive;
    /// xyz = dielectric F0 from `KHR_materials_ior` / `_specular`, w = specular intensity.
    /// (0.04, 1) is what `MeshStandardMaterial` hard-codes and what a plain material sends.
    float4   specular;
    /// x = `KHR_materials_transmission`, yzw unused.
    float4   surface;
};

// MARK: - Shadows

/// Percentage-closer filter over the spotlight's depth map. Returns 1 in full light, 0 in
/// full shadow. Stands in for three.js `PCFSoftShadowMap` at the default `shadow.radius` of 1.
static float sampleShadow(constant SceneUniforms &scene,
                          depth2d<float> shadowMap,
                          sampler shadowSampler,
                          float3 worldPosition)
{
    if (scene.shadowParams.z < 0.5) { return 1.0; }

    float4 lightClip = scene.lightViewProjection * float4(worldPosition, 1.0);
    if (lightClip.w <= 0.0) { return 1.0; }

    float3 ndc = lightClip.xyz / lightClip.w;
    // Outside the shadow frustum three.js leaves the fragment lit — the spot cone attenuation
    // is what darkens it, not the shadow map.
    if (abs(ndc.x) > 1.0 || abs(ndc.y) > 1.0 || ndc.z < 0.0 || ndc.z > 1.0) { return 1.0; }

    float2 uv = float2(ndc.x * 0.5 + 0.5, -ndc.y * 0.5 + 0.5);
    float reference = ndc.z - scene.shadowParams.y;
    float texel = scene.shadowParams.x;

    float sum = 0.0;
    for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
            sum += shadowMap.sample_compare(shadowSampler,
                                            uv + float2(float(x), float(y)) * texel,
                                            reference);
        }
    }
    return sum / 9.0;
}

// MARK: - Lighting

/// Scalar irradiance reaching a surface, before the BRDF.
///
/// Port of the ambient + spot rig at `main.js:47-61`. The light is white, so this collapses to
/// one channel. `decay = 0` and `distance = 0` in the JS, which makes three.js's distance
/// attenuation exactly 1 at every range — that is the "uniform map brightness" the comment
/// there is describing, and it is why no falloff term appears here.
struct LightSample {
    float ambient;
    float direct;      ///< dotNL · intensity · spot attenuation · shadow
    float3 direction;  ///< unit vector from the surface towards the light
};

static LightSample sampleLight(constant SceneUniforms &scene,
                               float3 worldPosition,
                               float3 normal,
                               float shadow)
{
    LightSample out;
    out.ambient = scene.lightParams.x;

    float3 lightDir = normalize(scene.lightPosition.xyz - worldPosition);
    out.direction = lightDir;

    // three.js `getSpotAttenuation`: smoothstep between the cone and penumbra cosines.
    float angleCos = dot(lightDir, scene.lightDirection.xyz);
    float spotAttenuation = smoothstep(scene.lightParams.z, scene.lightParams.w, angleCos);

    float dotNL = saturate(dot(normal, lightDir));
    out.direct = scene.lightParams.y * dotNL * spotAttenuation * shadow;
    return out;
}

/// `MeshLambertMaterial` — diffuse only, no specular term (the ground layers).
static float3 shadeLambert(float3 albedo, LightSample light)
{
    return albedo * RECIPROCAL_PI * (light.ambient + light.direct);
}

// GGX helpers, ported from three.js `bsdfs.glsl.js`.
///
/// `f90` is 1 for `MeshStandardMaterial`, which is what a material carrying no
/// `KHR_materials_specular` sends — so this collapses to the two-argument form it replaced.
static float3 fresnelSchlick(float3 f0, float f90, float dotVH)
{
    float fresnel = exp2((-5.55473 * dotVH - 6.98316) * dotVH);
    return f0 * (1.0 - fresnel) + f90 * fresnel;
}

static float smithCorrelatedVisibility(float alpha, float dotNL, float dotNV)
{
    float a2 = alpha * alpha;
    float gv = dotNL * sqrt(a2 + (1.0 - a2) * dotNV * dotNV);
    float gl = dotNV * sqrt(a2 + (1.0 - a2) * dotNL * dotNL);
    return 0.5 / max(gv + gl, 1e-6);
}

static float distributionGGX(float alpha, float dotNH)
{
    float a2 = alpha * alpha;
    float denom = dotNH * dotNH * (a2 - 1.0) + 1.0;
    return RECIPROCAL_PI * a2 / (denom * denom);
}

/// `MeshStandardMaterial` — the rig limbs and the imported head/shoe/prop meshes — and the
/// `MeshPhysicalMaterial` three.js promotes a material to once it carries
/// `KHR_materials_ior`, `_specular` or `_transmission`.
///
/// Without an environment map three.js contributes no indirect specular at all, so the
/// ambient term is diffuse-only and the GGX lobe rides on the spotlight alone.
///
/// `diffuseScale` is `1 − transmission`: the diffuse lobe of a transmissive surface is
/// replaced by what lies behind it, and the caller supplies that by blending. The specular
/// lobe is *not* scaled, because a glass surface keeps its highlight — which is why the
/// result is returned already premultiplied by coverage.
static float3 shadeStandard(float3 albedo,
                            float roughness,
                            float metalness,
                            float3 dielectricF0,
                            float specularIntensity,
                            float diffuseScale,
                            float3 normal,
                            float3 viewDir,
                            LightSample light)
{
    float3 diffuseColor = albedo * (1.0 - metalness);
    // three.js `MeshPhysicalMaterial`: F0 mixes the dielectric reflectance towards the albedo
    // by metalness, and F90 mixes the specular intensity towards 1 the same way.
    float3 specularColor = mix(dielectricF0, albedo, metalness);
    float specularF90 = mix(specularIntensity, 1.0, metalness);

    float3 color = diffuseColor * diffuseScale * RECIPROCAL_PI * (light.ambient + light.direct);

    if (light.direct > 0.0) {
        float alpha = max(roughness, 0.0525);
        alpha *= alpha;

        float3 halfDir = normalize(light.direction + viewDir);
        float dotNL = saturate(dot(normal, light.direction));
        float dotNV = saturate(dot(normal, viewDir));
        float dotNH = saturate(dot(normal, halfDir));
        float dotVH = saturate(dot(viewDir, halfDir));

        float3 f = fresnelSchlick(specularColor, specularF90, dotVH);
        float v = smithCorrelatedVisibility(alpha, dotNL, dotNV);
        float d = distributionGGX(alpha, dotNH);
        color += light.direct * f * (v * d);
    }

    return color;
}

// MARK: - Textured quads (map chunk tiles)

struct QuadInOut {
    float4 position [[position]];
    float2 uv;
    float4 tint;
    float4 flags;
    float3 worldPosition;
};

/// Colour plus the view-space normal the SSAO pass reads back.
struct SceneOut {
    float4 color  [[color(0)]];
    float4 normal [[color(1)]];
};

static float4 packViewNormal(constant SceneUniforms &scene, float3 worldNormal)
{
    float3 viewNormal = normalize((scene.view * float4(normalize(worldNormal), 0.0)).xyz);
    return float4(viewNormal * 0.5 + 0.5, 1.0);
}

vertex QuadInOut quadVertex(uint vertexID [[vertex_id]],
                            const device QuadVertex *vertices [[buffer(0)]],
                            constant DrawUniforms &uniforms [[buffer(1)]])
{
    QuadInOut out;
    float3 p = vertices[vertexID].position;
    out.position = uniforms.modelViewProjection * float4(p, 1.0);
    out.uv = vertices[vertexID].uv;
    out.tint = uniforms.tint;
    out.flags = uniforms.flags;
    out.worldPosition = (uniforms.model * float4(p, 1.0)).xyz;
    return out;
}

fragment SceneOut quadFragment(QuadInOut in [[stage_in]],
                               constant SceneUniforms &scene [[buffer(2)]],
                               texture2d<float> image [[texture(0)]],
                               depth2d<float> shadowMap [[texture(2)]],
                               sampler imageSampler [[sampler(0)]],
                               sampler shadowSampler [[sampler(2)]])
{
    float4 color = image.sample(imageSampler, in.uv);
    color.a *= in.tint.a;
    if (color.a <= 0.001) { discard_fragment(); }

    // Tiles lie flat on the ground plane, so their normal is render-space +Z.
    const float3 normal = float3(0.0, 0.0, 1.0);

    SceneOut out;
    if (in.flags.x > 0.5) {
        float shadow = sampleShadow(scene, shadowMap, shadowSampler, in.worldPosition);
        LightSample light = sampleLight(scene, in.worldPosition, normal, shadow);
        out.color = float4(shadeLambert(color.rgb, light), color.a);
    } else {
        // Overlay layers are `MeshBasicMaterial` in the JS — flat and unlit.
        out.color = color;
    }
    out.normal = packViewNormal(scene, normal);
    return out;
}

// MARK: - Characters and props (procedural rig, glTF meshes) with clip-mask occlusion

struct CharacterInOut {
    float4 position [[position]];
    float3 normal;
    float2 uv;
    float3 worldPosition;
    /// Base colour. Comes from the uniforms for a rigid draw and from the palette for a skinned
    /// one, so a single fragment shader serves both. Every vertex of one surface carries the
    /// same slot, so there is nothing for the interpolation to smear.
    float4 tint;
    /// x = roughness, y = metalness.
    float2 surfaceParams;
};

vertex CharacterInOut characterVertex(uint vertexID [[vertex_id]],
                                      const device MeshVertex *vertices [[buffer(0)]],
                                      constant CharacterUniforms &uniforms [[buffer(1)]])
{
    CharacterInOut out;
    float4 local = float4(vertices[vertexID].position, 1.0);

    out.position = uniforms.modelViewProjection * local;
    out.normal = normalize((uniforms.model * float4(vertices[vertexID].normal, 0.0)).xyz);
    out.uv = vertices[vertexID].uv;
    out.worldPosition = (uniforms.model * local).xyz;
    out.tint = uniforms.color;
    out.surfaceParams = uniforms.flags.zw;
    return out;
}

/// **Linear blend skinning for the character body.**
///
/// Each matrix in `joints` is that bone's transform this frame times the inverse of its
/// transform in the pose the mesh was built in, so it carries a bind-space vertex to where the
/// bone has taken it. A vertex on a bone's shaft is moved by that one matrix; a vertex near a
/// joint is moved by a weighted sum of the two bones meeting there, and that sum is what makes
/// an elbow a crease rather than the seam between two capsules.
///
/// The character's position, heading and scale are already inside every joint matrix, so
/// `modelViewProjection` is the plain view-projection and there is no model matrix to apply.
vertex CharacterInOut characterSkinnedVertex(uint vertexID [[vertex_id]],
                                             const device SkinVertex *vertices [[buffer(0)]],
                                             constant CharacterUniforms &uniforms [[buffer(1)]],
                                             constant float4x4 *joints [[buffer(2)]],
                                             constant float4 *palette [[buffer(3)]])
{
    SkinVertex v = vertices[vertexID];

    float3 position = float3(0.0);
    float3 normal = float3(0.0);
    for (uint i = 0; i < 4; i++) {
        float weight = v.weights[i];
        if (weight <= 0.0) { continue; }
        float4x4 bone = joints[uint(v.joints[i])];
        position += weight * (bone * float4(v.position, 1.0)).xyz;
        normal += weight * (float3x3(bone[0].xyz, bone[1].xyz, bone[2].xyz) * v.normal);
    }

    uint slot = uint(v.colorSlot);
    CharacterInOut out;
    out.position = uniforms.modelViewProjection * float4(position, 1.0);
    out.normal = normalize(normal);
    out.uv = v.uv;
    out.worldPosition = position;
    // The palette holds the colours first and the roughness/metalness pairs after them.
    out.tint = float4(palette[slot].rgb, uniforms.color.a);
    out.surfaceParams = palette[slot + SKIN_PALETTE_COUNT].xy;
    return out;
}

fragment SceneOut characterFragment(CharacterInOut in [[stage_in]],
                                    constant CharacterUniforms &uniforms [[buffer(1)]],
                                    constant SceneUniforms &scene [[buffer(2)]],
                                    texture2d<float> baseColor [[texture(0)]],
                                    texture2d<float> clipMap [[texture(1)]],
                                    depth2d<float> shadowMap [[texture(2)]],
                                    texture2d<float> emissiveMap [[texture(3)]],
                                    sampler baseSampler [[sampler(0)]],
                                    sampler clipSampler [[sampler(1)]],
                                    sampler shadowSampler [[sampler(2)]])
{
    float4 color = in.tint;
    if (uniforms.flags.x > 0.5) {
        color *= baseColor.sample(baseSampler, in.uv);
    }
    if (color.a <= 0.001) { discard_fragment(); }

    // Clip-mask occlusion. 1:1 port of the GLSL injected into the three.js material at
    // characters.js:388-420 — march from this fragment towards the character's own pivot and
    // discard if any step lands on a black (wall) pixel, so limbs vanish behind buildings.
    float mapW = uniforms.clipParams.z;
    float mapH = uniforms.clipParams.w;

    if (mapW > 0.0 && mapH > 0.0) {
        float2 fragPos = in.worldPosition.xy;
        float2 dir = uniforms.clipParams.xy - fragPos;
        float dist = length(dir);
        float2 dirNorm = dist > 0.001 ? dir / dist : float2(0.0);

        const int MAX_STEPS = 10;
        bool occluded = false;

        for (int i = 0; i <= MAX_STEPS; i++) {
            float t = float(i) / float(MAX_STEPS);
            float2 testWorld = fragPos + dirNorm * (dist * t);

            float2 clipUv = float2((testWorld.x + mapW * 0.5) / mapW,
                                   (-testWorld.y + mapH * 0.5) / mapH);

            if (clipUv.x >= 0.0 && clipUv.x <= 1.0 && clipUv.y >= 0.0 && clipUv.y <= 1.0) {
                float4 clipColor = clipMap.sample(clipSampler, clipUv);
                if (clipColor.r < 0.1 && clipColor.g < 0.1 && clipColor.b < 0.1) {
                    occluded = true;
                    break;
                }
            }
        }

        if (occluded) { discard_fragment(); }
    }

    float3 normal = normalize(in.normal);

    SceneOut out;
    if (uniforms.flags.y > 0.5) {
        // The shadow blob is a `MeshBasicMaterial` in the JS — flat, unlit, no emission.
        out.color = color;
    } else {
        float shadow = sampleShadow(scene, shadowMap, shadowSampler, in.worldPosition);
        LightSample light = sampleLight(scene, in.worldPosition, normal, shadow);
        float3 viewDir = normalize(scene.cameraPosition.xyz - in.worldPosition);

        // `KHR_materials_transmission`: three.js replaces the diffuse lobe with a sample of
        // the backdrop it renders to a separate target. There is no such target here, so the
        // diffuse lobe is dropped by `transmission` and the surface is made that much more
        // transparent instead — the transmissive pipeline blends premultiplied, which makes
        // the composite `mix(diffuse, backdrop, transmission) + specular`. What is missing
        // against three.js is the *refraction* and the roughness blur of that backdrop, not
        // the see-through itself.
        float transmission = uniforms.surface.x;

        float3 shaded = shadeStandard(color.rgb, in.surfaceParams.x, in.surfaceParams.y,
                                      uniforms.specular.xyz, uniforms.specular.w,
                                      1.0 - transmission,
                                      normal, viewDir, light);

        // `totalEmissiveRadiance`, added after the lighting exactly as three.js does.
        float3 emissive = uniforms.emissive.xyz;
        if (uniforms.emissive.w > 0.5) {
            emissive *= emissiveMap.sample(baseSampler, in.uv).rgb;
        }

        out.color = float4(shaded + emissive, color.a * (1.0 - transmission));
    }
    out.normal = packViewNormal(scene, normal);
    return out;
}

// MARK: - Shadow map pass

/// Depth-only. The pipeline binds no fragment function, so this just transforms the vertex by
/// the light's view-projection (passed in `modelViewProjection`).
vertex float4 shadowVertex(uint vertexID [[vertex_id]],
                           const device MeshVertex *vertices [[buffer(0)]],
                           constant CharacterUniforms &uniforms [[buffer(1)]])
{
    return uniforms.modelViewProjection * float4(vertices[vertexID].position, 1.0);
}

/// The same, for the skinned body. A character casts the shadow of the pose it is actually in,
/// so the skinning has to be repeated here rather than the rest pose reused.
vertex float4 shadowSkinnedVertex(uint vertexID [[vertex_id]],
                                  const device SkinVertex *vertices [[buffer(0)]],
                                  constant CharacterUniforms &uniforms [[buffer(1)]],
                                  constant float4x4 *joints [[buffer(2)]])
{
    SkinVertex v = vertices[vertexID];
    float3 position = float3(0.0);
    for (uint i = 0; i < 4; i++) {
        float weight = v.weights[i];
        if (weight <= 0.0) { continue; }
        position += weight * (joints[uint(v.joints[i])] * float4(v.position, 1.0)).xyz;
    }
    return uniforms.modelViewProjection * float4(position, 1.0);
}

// MARK: - Post-processing

struct FullscreenInOut {
    float4 position [[position]];
    float2 uv;
};

/// Oversized triangle covering the viewport; no vertex buffer needed.
vertex FullscreenInOut fullscreenVertex(uint vertexID [[vertex_id]])
{
    float2 ndc = float2((vertexID == 2) ? 3.0 : -1.0,
                        (vertexID == 1) ? 3.0 : -1.0);
    FullscreenInOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.uv = float2(ndc.x * 0.5 + 0.5, -ndc.y * 0.5 + 0.5);
    return out;
}

/// three.js `perspectiveDepthToViewZ`. Our projection matrix maps z into [0, 1] exactly like
/// three.js's does after the viewport transform, so the formula carries over unchanged.
static float perspectiveDepthToViewZ(float depth, float near, float far)
{
    return (near * far) / ((far - near) * depth - far);
}

static float viewZToOrthographicDepth(float viewZ, float near, float far)
{
    return (viewZ + near) / (near - far);
}

static float3 viewPositionFromDepth(constant SceneUniforms &scene, float2 uv, float depth)
{
    float4 clip = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, depth, 1.0);
    float4 viewPosition = scene.inverseProjection * clip;
    return viewPosition.xyz / viewPosition.w;
}

/// Hash standing in for three.js's 4×4 tiled noise texture — same purpose, no upload.
static float hash12(float2 p)
{
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

/// Port of three.js `SSAOShader` with the pass's shipped settings (`main.js:74-77`):
/// `kernelRadius = 32`, `minDistance = 1e-6`, `maxDistance = 1.5`.
///
/// `samples[i]` is generated on the CPU exactly as `SSAOPass.generateSampleKernel` does and
/// arrives in buffer 3. (`kernel` is a reserved word in MSL, hence the rename.)
fragment float ssaoFragment(FullscreenInOut in [[stage_in]],
                            constant SceneUniforms &scene [[buffer(2)]],
                            constant float4 *samples [[buffer(3)]],
                            constant float4 &settings [[buffer(4)]],
                            depth2d<float> depthMap [[texture(0)]],
                            texture2d<float> normalMap [[texture(1)]],
                            sampler pointSampler [[sampler(0)]])
{
    const int KERNEL_SIZE = 32;

    float near = scene.cameraParams.x;
    float far = scene.cameraParams.y;
    float kernelRadius = settings.x;
    float minDistance = settings.y;
    float maxDistance = settings.z;

    float depth = depthMap.sample(pointSampler, in.uv);
    if (depth >= 1.0) { return 1.0; }   // Nothing was drawn here.

    float3 viewPosition = viewPositionFromDepth(scene, in.uv, depth);
    float3 viewNormal = normalize(normalMap.sample(pointSampler, in.uv).xyz * 2.0 - 1.0);

    // Build a tangent frame randomly spun about the normal, as the JS does with its noise map.
    float angle = hash12(in.uv * scene.cameraParams.zw) * 2.0 * PI;
    float3 randomVector = normalize(float3(cos(angle), sin(angle), 0.0));
    float3 tangent = normalize(randomVector - viewNormal * dot(randomVector, viewNormal));
    float3 bitangent = cross(viewNormal, tangent);
    float3x3 kernelMatrix = float3x3(tangent, bitangent, viewNormal);

    float occlusion = 0.0;
    for (int i = 0; i < KERNEL_SIZE; ++i) {
        float3 sampleVector = normalize(kernelMatrix * samples[i].xyz);
        float3 samplePoint = viewPosition + sampleVector * kernelRadius;

        float4 samplePointNDC = scene.projection * float4(samplePoint, 1.0);
        samplePointNDC /= samplePointNDC.w;
        float2 sampleUv = float2(samplePointNDC.x * 0.5 + 0.5, 0.5 - samplePointNDC.y * 0.5);
        if (sampleUv.x < 0.0 || sampleUv.x > 1.0 || sampleUv.y < 0.0 || sampleUv.y > 1.0) {
            continue;
        }

        float sceneDepth = depthMap.sample(pointSampler, sampleUv);
        float realDepth = viewZToOrthographicDepth(
            perspectiveDepthToViewZ(sceneDepth, near, far), near, far);
        float sampleDepth = viewZToOrthographicDepth(samplePoint.z, near, far);

        float delta = sampleDepth - realDepth;
        if (delta > minDistance && delta < maxDistance) { occlusion += 1.0; }
    }

    return 1.0 - saturate(occlusion / float(KERNEL_SIZE));
}

/// three.js `SSAOBlurShader`: a flat 5×5 box over the AO buffer.
fragment float ssaoBlurFragment(FullscreenInOut in [[stage_in]],
                                constant float4 &texelSize [[buffer(0)]],
                                texture2d<float> ao [[texture(0)]],
                                sampler linearSampler [[sampler(0)]])
{
    float result = 0.0;
    for (int y = -2; y <= 2; ++y) {
        for (int x = -2; x <= 2; ++x) {
            result += ao.sample(linearSampler,
                                in.uv + float2(float(x), float(y)) * texelSize.xy).r;
        }
    }
    return result / 25.0;
}

/// Final resolve: the beauty buffer multiplied by ambient occlusion, matching the multiply
/// blend `SSAOPass` uses to composite its blurred AO over the scene.
///
/// The result stays linear; the `_srgb` drawable applies the single sRGB encode that the web
/// build's `OutputPass` does. Verified against the live client by luminance histogram: its
/// p75/p95 are 156.3/179.7 against this pipeline's 157.8/179.8.
fragment float4 compositeFragment(FullscreenInOut in [[stage_in]],
                                  constant float4 &settings [[buffer(0)]],
                                  texture2d<float> sceneColor [[texture(0)]],
                                  texture2d<float> ao [[texture(1)]],
                                  sampler linearSampler [[sampler(0)]])
{
    float4 color = sceneColor.sample(linearSampler, in.uv);
    if (settings.x > 0.5) {
        color.rgb *= ao.sample(linearSampler, in.uv).r;
    }
    return color;
}
