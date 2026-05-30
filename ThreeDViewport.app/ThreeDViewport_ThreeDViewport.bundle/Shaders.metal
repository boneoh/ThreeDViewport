#include <metal_stdlib>
using namespace metal;

// ── Shared structs (must match ShaderTypes.swift exactly) ────────────────────

struct Uniforms {
    float4x4 modelMatrix;
    float4x4 viewProjectionMatrix;
    float4x4 normalMatrix;
    float4   cameraPosition;   // xyz = world pos, w unused
};

// Light type constants stored in ShaderLight.position.w
#define LIGHT_AMBIENT     0
#define LIGHT_DIRECTIONAL 1
#define LIGHT_POINT       2
#define LIGHT_SPOT        3
#define LIGHT_LASER       4

struct ShaderLight {
    float4 position;   // xyz=world pos,  w=type
    float4 direction;  // xyz=direction,  w=unused
    float4 color;      // xyz=RGB×intens, w=intensity
    float4 params;     // x=cos(inner), y=cos(outer), z=range, w=unused
};

struct LightUniforms {
    float4      ambientColor;
    uint4       countAndPad;   // x = lightCount
    ShaderLight lights[4];
};

struct MaterialUniforms {
    float4  baseColorFactor;
    float4  emissiveFactor;      // w unused
    float   metallicFactor;
    float   roughnessFactor;
    uint    hasBaseColorTex;
    uint    hasNormalTex;
    uint    hasMetallicRoughTex;
    uint    hasEmissiveTex;
    uint    colorMode;           // 0=greyscale, 1=color, 2=black+white
    uint    useFlatNormals;      // 0=vertex normals, 1=derivatives
    float   opacity;             // multiplied into fragment alpha
};

struct BackgroundUniforms {
    float4 colorTop;
    float4 colorBottom;
};

// ── Scene vertex / fragment ───────────────────────────────────────────────────

struct VertexOut {
    float4 position      [[position]];
    float3 worldNormal;
    float3 worldPosition;
    float2 uv;
    float3 worldTangent;
    float3 worldBitangent;
};

vertex VertexOut vertex_main(
    uint                    vid       [[vertex_id]],
    constant packed_float3 *positions [[buffer(0)]],
    constant packed_float3 *normals   [[buffer(1)]],
    constant Uniforms      &uniforms  [[buffer(2)]],
    constant packed_float2 *uvs       [[buffer(4)]],
    constant packed_float4 *tangents  [[buffer(5)]]   // xyz=tangent, w=handedness
) {
    VertexOut out;

    float3 pos  = float3(positions[vid]);
    float3 norm = float3(normals[vid]);

    float4 worldPos4  = uniforms.modelMatrix * float4(pos, 1.0);
    out.position      = uniforms.viewProjectionMatrix * worldPos4;
    out.worldPosition = worldPos4.xyz;

    // Normal matrix: upper-left 3x3 of the provided normalMatrix (inverse-transpose of model)
    float3x3 normalMat = float3x3(
        uniforms.normalMatrix.columns[0].xyz,
        uniforms.normalMatrix.columns[1].xyz,
        uniforms.normalMatrix.columns[2].xyz
    );
    float3 N = normalize(normalMat * norm);
    out.worldNormal = N;

    // Tangent frame (for normal mapping)
    float4 tang = tangents[vid];
    float3 T    = normalize(normalMat * tang.xyz);
    // Gram-Schmidt re-orthogonalise against N
    T = normalize(T - dot(T, N) * N);
    float3 B = cross(N, T) * tang.w;   // handedness from w component
    out.worldTangent   = T;
    out.worldBitangent = B;

    out.uv = float2(uvs[vid]);

    return out;
}

// ── PBR BRDF helpers ─────────────────────────────────────────────────────────

// GGX / Trowbridge-Reitz normal distribution function
static float D_GGX(float NdotH, float roughness) {
    float a  = roughness * roughness;
    float a2 = a * a;
    float d  = NdotH * NdotH * (a2 - 1.0) + 1.0;
    return a2 / (M_PI_F * d * d + 1e-7);
}

// Smith-GGX combined geometry term (Schlick approximation)
static float G_Smith(float NdotV, float NdotL, float roughness) {
    float r  = roughness + 1.0;
    float k  = (r * r) / 8.0;
    float gV = NdotV / (NdotV * (1.0 - k) + k);
    float gL = NdotL / (NdotL * (1.0 - k) + k);
    return gV * gL;
}

// Fresnel-Schlick approximation
static float3 F_Schlick(float cosTheta, float3 F0) {
    return F0 + (1.0 - F0) * pow(saturate(1.0 - cosTheta), 5.0);
}

// ── Light attenuation / direction helper ────────────────────────────────────
// Returns true if the light contributes; fills out L (toward light) and
// attenuation. Mirrors the geometry logic from the old evaluateLight.
static bool sampleLight(ShaderLight light,
                         float3      worldPos,
                         thread float3 &L,
                         thread float  &attenuation)
{
    int lightType = int(light.position.w);

    if (lightType == LIGHT_AMBIENT) { return false; }

    if (lightType == LIGHT_DIRECTIONAL) {
        L           = normalize(-light.direction.xyz);
        attenuation = 1.0;
        return true;
    }

    // Positional
    float3 toLight = light.position.xyz - worldPos;
    float  dist    = length(toLight);
    float  range   = light.params.z;
    if (dist >= range) return false;

    L = normalize(toLight);

    // Laser: constant intensity — no distance falloff along the beam.
    if (lightType == LIGHT_LASER) {
        attenuation = 1.0;
    } else {
        float normDist = dist / range;
        attenuation    = pow(max(0.0, 1.0 - normDist * normDist), 2.0);
    }

    if (lightType == LIGHT_SPOT || lightType == LIGHT_LASER) {
        float3 surfaceDir = normalize(worldPos - light.position.xyz);
        float  cosAngle   = dot(surfaceDir, normalize(light.direction.xyz));
        float  cosOuter   = light.params.y;
        float  cosInner   = light.params.x;
        if (cosAngle < cosOuter) return false;
        float spotAtten = (lightType == LIGHT_LASER)
            ? (cosAngle >= cosInner ? 1.0 : 0.0)
            : smoothstep(cosOuter, cosInner, cosAngle);
        attenuation *= spotAtten;
    }

    return true;
}

// ── Scene fragment shader ─────────────────────────────────────────────────────

fragment float4 fragment_main(
    VertexOut               in            [[stage_in]],
    constant Uniforms      &uniforms      [[buffer(2)]],
    constant LightUniforms &lightData     [[buffer(3)]],
    constant MaterialUniforms &matData    [[buffer(4)]],
    texture2d<float>        baseColorTex  [[texture(0)]],
    texture2d<float>        normalTex     [[texture(1)]],
    texture2d<float>        mrTex         [[texture(2)]],
    texture2d<float>        emissiveTex   [[texture(3)]],
    // Phase C: image-based lighting.  Intensity travels in lightData.ambientColor.w.
    texturecube<float>      iblIrradiance [[texture(4)]],
    texturecube<float>      iblSpecular   [[texture(5)]],
    texture2d<float>        iblBRDF       [[texture(6)]]
) {
    constexpr sampler texSampler(filter::linear,
                                  mip_filter::linear,
                                  address::repeat);
    constexpr sampler envSampler(filter::linear,
                                  mip_filter::linear,
                                  address::clamp_to_edge);

    // ── Surface normal ─────────────────────────────────────────────────────
    float3 N;
    if (matData.useFlatNormals != 0) {
        // True per-face normal from screen-space derivatives of world position.
        // Used when the file shipped no normals, or when the user picks Flat mode.
        N = normalize(cross(dfdx(in.worldPosition), dfdy(in.worldPosition)));
        // Orient consistent with the stored vertex normal (handles winding/handedness).
        if (dot(N, in.worldNormal) < 0.0) N = -N;
    } else {
        N = normalize(in.worldNormal);
        if (matData.hasNormalTex) {
            float3 tangentNormal = normalTex.sample(texSampler, in.uv).rgb * 2.0 - 1.0;
            float3x3 TBN = float3x3(normalize(in.worldTangent),
                                     normalize(in.worldBitangent),
                                     N);
            N = normalize(TBN * tangentNormal);
        }
    }

    // ── View direction ─────────────────────────────────────────────────────
    float3 V = normalize(uniforms.cameraPosition.xyz - in.worldPosition);

    // ── Base color ─────────────────────────────────────────────────────────
    float4 baseColor = matData.baseColorFactor;
    if (matData.hasBaseColorTex) {
        // Texture was loaded as sRGB — Metal linearises on sample automatically
        baseColor *= baseColorTex.sample(texSampler, in.uv);
    }
    float3 albedo = baseColor.rgb;

    // ── Metallic / roughness ───────────────────────────────────────────────
    float metallic  = matData.metallicFactor;
    float roughness = matData.roughnessFactor;
    if (matData.hasMetallicRoughTex) {
        float4 mr = mrTex.sample(texSampler, in.uv);
        metallic  *= mr.b;   // metallic  = blue channel
        roughness *= mr.g;   // roughness = green channel
    }
    roughness = max(roughness, 0.04);   // clamp to avoid singularities

    // ── PBR dielectric/metallic F0 ─────────────────────────────────────────
    float3 F0 = mix(float3(0.04), albedo, metallic);

    // ── Ambient / IBL diffuse ──────────────────────────────────────────────
    // When IBL is active (intensity > 0), the diffuse irradiance cubemap
    // replaces the flat ambientColor.rgb term.  Ambient-type lights placed by
    // the user are treated as additional fill and still contribute either way.
    float iblIntensity = lightData.ambientColor.w;
    uint count = lightData.countAndPad.x;
    float3 color;
    if (iblIntensity > 0.0) {
        float3 irradiance = iblIrradiance.sample(envSampler, N).rgb;
        color = irradiance * iblIntensity * albedo * (1.0 - metallic);
        for (uint i = 0; i < count; i++) {
            if (int(lightData.lights[i].position.w) == LIGHT_AMBIENT) {
                color += lightData.lights[i].color.rgb * albedo * (1.0 - metallic * 0.9);
            }
        }
    } else {
        float3 ambientLight = lightData.ambientColor.rgb;
        for (uint i = 0; i < count; i++) {
            if (int(lightData.lights[i].position.w) == LIGHT_AMBIENT) {
                ambientLight += lightData.lights[i].color.rgb;
            }
        }
        color = ambientLight * albedo * (1.0 - metallic * 0.9);
    }

    // ── Per-light BRDF accumulation ────────────────────────────────────────
    float NdotV = max(dot(N, V), 0.0001);

    for (uint i = 0; i < count; i++) {
        ShaderLight light = lightData.lights[i];
        if (int(light.position.w) == LIGHT_AMBIENT) { continue; }

        float3 L;
        float  atten;
        if (!sampleLight(light, in.worldPosition, L, atten)) { continue; }

        float3 H     = normalize(V + L);
        float  NdotL = max(dot(N, L), 0.0);
        float  NdotH = max(dot(N, H), 0.0);
        float  VdotH = max(dot(V, H), 0.0);

        if (NdotL <= 0.0) { continue; }

        // Cook-Torrance specular BRDF
        float  D = D_GGX(NdotH, roughness);
        float  G = G_Smith(NdotV, NdotL, roughness);
        float3 F = F_Schlick(VdotH, F0);

        float3 specular = (D * G * F) / max(4.0 * NdotV * NdotL, 0.001);

        // Lambertian diffuse (energy-conserving: metals have no diffuse)
        float3 kD      = (float3(1.0) - F) * (1.0 - metallic);
        float3 diffuse = kD * albedo / M_PI_F;

        color += (diffuse + specular) * NdotL * light.color.rgb * atten;
    }

    // ── IBL specular (split-sum approximation) ─────────────────────────────
    // Mip level is roughness × (numMips - 1).  BRDF LUT folds in the F0
    // scale + bias so we don't re-importance-sample at runtime.
    if (iblIntensity > 0.0) {
        float3 R       = reflect(-V, N);
        float  mipMax  = float(iblSpecular.get_num_mip_levels() - 1);
        float  lod     = roughness * mipMax;
        float3 prefilt = iblSpecular.sample(envSampler, R, level(lod)).rgb;
        float2 brdf    = iblBRDF.sample(envSampler, float2(NdotV, roughness)).rg;
        float3 specIBL = prefilt * (F0 * brdf.x + brdf.y);
        color += specIBL * iblIntensity;
    }

    // ── Emissive ───────────────────────────────────────────────────────────
    float3 emissive = matData.emissiveFactor.rgb;
    if (matData.hasEmissiveTex) {
        emissive *= emissiveTex.sample(texSampler, in.uv).rgb;
    }
    color += emissive;

    // ── Exposure (pre-tone-map) ────────────────────────────────────────────
    // Lives in the Color Grade panel/data but is applied HERE, before tone
    // mapping — scaling after the curve can't recover clipped highlights.
    // Travels in the spare countAndPad.y slot as a bit-cast float.
    float exposure = as_type<float>(lightData.countAndPad.y);
    if (exposure <= 0.0) { exposure = 1.0; }   // guard uninitialised paths
    color *= exposure;

    // ── Tone mapping (ACES filmic — Narkowicz approximation) ───────────────
    float3 acesA = color * (2.51 * color + 0.03);
    float3 acesB = color * (2.43 * color + 0.59) + 0.14;
    color = saturate(acesA / acesB);

    // ── Gamma encode for .bgra8Unorm render target ─────────────────────────
    color = pow(saturate(color), float3(1.0 / 2.2));

    // ── Render mode ───────────────────────────────────────────────────────
    //   0 = greyscale (Rec.709 luminance)
    //   1 = color (leave as-is)
    //   2 = black + white matte: every object fragment is solid white so it
    //       forms a clean, hole-free silhouette over the (black) background.
    if (matData.colorMode == 0) {
        float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
        color = float3(luma);
    } else if (matData.colorMode == 2) {
        color = float3(1.0);
    }

    // Output alpha = baseColorFactor.w × opacity.  For the opaque pipeline
    // (blend off) this just writes a=1 as before; the transparent pipeline
    // uses this alpha to blend against the destination.
    float outAlpha = baseColor.a * matData.opacity;
    return float4(color, outAlpha);
}

// ── Holdout fragment ──────────────────────────────────────────────────────────
// Reuses vertex_main for transform.  Writes depth (so holdout objects occlude
// geometry behind them) AND overwrites colour with a transparent matte —
// RGB black, alpha 0 — punching a clean hole through the background skybox so
// the silhouette reads as empty background instead of showing the IBL.
fragment float4 holdout_fragment(VertexOut in [[stage_in]]) {
    return float4(0.0, 0.0, 0.0, 0.0);
}

// ── Background gradient ───────────────────────────────────────────────────────

struct BgVertOut {
    float4 position [[position]];
    float  y;          // 0 = bottom of screen, 1 = top
};

vertex BgVertOut background_vertex(uint vid [[vertex_id]]) {
    const float2 pos[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };
    float2 p = pos[vid];
    BgVertOut out;
    out.position = float4(p, 0.999, 1.0);
    out.y        = p.y * 0.5 + 0.5;
    return out;
}

fragment float4 background_fragment(
    BgVertOut                   in [[stage_in]],
    constant BackgroundUniforms &bg [[buffer(0)]]
) {
    float3 color = mix(bg.colorBottom.rgb, bg.colorTop.rgb, in.y);
    // Alpha=0 marks this as a background pixel.
    // The feedback blend shader uses scene.a to distinguish background (0) from
    // geometry (1) so blend modes only interact with actual rendered content.
    // For the non-feedback path (direct-to-drawable), alpha is ignored by the display.
    return float4(color, 0.0);
}

// ── Environment skybox background ───────────────────────────────────────────────
// Fullscreen pass drawn before scene geometry (far depth, so geometry draws over
// it).  Reconstructs the world-space camera ray per pixel (same inverse-VP trick
// as the fog pass) and samples the IBL environment by direction — the retained 2K
// equirect when available (sharp), otherwise the 256² env cube (procedural sky).

struct SkyboxUniforms {
    float4x4 inverseViewProjection;
    float4   cameraPos;     // xyz = world eye position
    float    intensity;     // brightness multiplier
    float    horizon;       // vertical shift of the sampled direction (backdrop only)
    uint     useEquirect;   // 1 = sample equirect, 0 = cube fallback
    uint     colorMode;     // 0 grey, 1 color, 2 B+W matte
};

struct SkyVertOut {
    float4 position [[position]];
    float2 ndc;             // clip-space xy in [-1,1], y up
};

vertex SkyVertOut skybox_vertex(uint vid [[vertex_id]]) {
    const float2 pos[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };
    float2 p = pos[vid];
    SkyVertOut out;
    out.position = float4(p, 0.999, 1.0);   // far depth — scene geometry overwrites it
    out.ndc      = p;
    return out;
}

fragment float4 skybox_fragment(
    SkyVertOut                in [[stage_in]],
    constant SkyboxUniforms   &u          [[buffer(0)]],
    texturecube<float>        envCube     [[texture(0)]],
    texture2d<float>          envEquirect [[texture(1)]]
) {
    // World-space ray for this pixel (same reconstruction as the fog pass).
    float4 farClip = u.inverseViewProjection * float4(in.ndc, 1.0, 1.0);
    float3 dir     = normalize(farClip.xyz / farClip.w - u.cameraPos.xyz);
    dir.y         -= u.horizon;          // raise/lower the backdrop (positive = up)
    dir            = normalize(dir);

    float3 col;
    if (u.useEquirect != 0u) {
        // Match equirect_to_cube_kernel exactly so the backdrop and IBL lighting
        // share orientation.
        float uu = atan2(dir.z, dir.x) / (2.0 * M_PI_F) + 0.5;   // azimuth, wraps
        float vv = acos(clamp(dir.y, -1.0, 1.0)) / M_PI_F;        // polar, 0 = up
        constexpr sampler s(s_address::repeat, t_address::clamp_to_edge, filter::linear);
        col = envEquirect.sample(s, float2(uu, vv)).rgb;
    } else {
        constexpr sampler s(filter::linear);
        col = envCube.sample(s, dir).rgb;
    }
    col *= u.intensity;

    // Black + White matte: background stays black behind the white silhouette.
    if (u.colorMode == 2u) return float4(0.0, 0.0, 0.0, 0.0);
    if (u.colorMode == 0u)                      // greyscale: match the desaturated scene
        col = float3(dot(col, float3(0.2126, 0.7152, 0.0722)));

    // Alpha = 0 marks this as a background pixel for the feedback blend.
    return float4(col, 0.0);
}

// ── Axes Gizmo ────────────────────────────────────────────────────────────────
// Simple 2-D overlay pass.  Each vertex is a screen-space NDC position plus
// an RGBA colour.  No depth buffer — gizmo always renders on top.

struct GizmoVertex {
    float4 position;   // xy = NDC, zw unused (set to 0,1 on Swift side)
    float4 color;
};

struct GizmoVOut {
    float4 position [[position]];
    float4 color;
};

vertex GizmoVOut gizmo_vertex(uint vid [[vertex_id]],
                               device const GizmoVertex *v [[buffer(0)]]) {
    GizmoVOut out;
    out.position = float4(v[vid].position.xy, 0.0, 1.0);
    out.color    = v[vid].color;
    return out;
}

fragment float4 gizmo_fragment(GizmoVOut in [[stage_in]]) {
    return in.color;
}
