#include <metal_stdlib>
using namespace metal;

// ── IBL precompute kernels ────────────────────────────────────────────────────
// One-time GPU work that produces the textures the scene fragment shader samples
// for image-based lighting.  All kernels write to .private textures; results are
// kept on the GPU between frames.
//
// Phases:
//   1. brdf_lut_kernel          — split-sum BRDF integration LUT.
//   2. env_cube_kernel          — procedural sky-gradient cubemap (fallback env).
//   2b. equirect_to_cube_kernel — projects a loaded equirect HDR into the env cube.
//   3. irradiance_cube_kernel   — cosine-weighted convolution (diffuse IBL).
//   4. prefilter_cube_kernel    — GGX importance-sampled mip per roughness level.

// ── Hammersley low-discrepancy sequence ──────────────────────────────────────
static float radicalInverse_VdC(uint bits) {
    bits = (bits << 16u) | (bits >> 16u);
    bits = ((bits & 0x55555555u) << 1u) | ((bits & 0xAAAAAAAAu) >> 1u);
    bits = ((bits & 0x33333333u) << 2u) | ((bits & 0xCCCCCCCCu) >> 2u);
    bits = ((bits & 0x0F0F0F0Fu) << 4u) | ((bits & 0xF0F0F0F0u) >> 4u);
    bits = ((bits & 0x00FF00FFu) << 8u) | ((bits & 0xFF00FF00u) >> 8u);
    return float(bits) * 2.3283064365386963e-10;   // / 0x100000000
}

static float2 hammersley(uint i, uint N) {
    return float2(float(i) / float(N), radicalInverse_VdC(i));
}

// GGX importance-sampled half vector in tangent space (N aligned to +Z).
static float3 importanceSampleGGX(float2 Xi, float roughness) {
    float a    = roughness * roughness;
    float phi  = 2.0 * M_PI_F * Xi.x;
    float cosT = sqrt((1.0 - Xi.y) / (1.0 + (a * a - 1.0) * Xi.y));
    float sinT = sqrt(max(0.0, 1.0 - cosT * cosT));
    return float3(cos(phi) * sinT, sin(phi) * sinT, cosT);
}

// Smith-GGX geometry term — IBL variant uses k = a² / 2 (Karis "Real Shading in UE4").
static float G_SmithIBL(float NdotV, float NdotL, float roughness) {
    float a  = roughness * roughness;
    float k  = (a * a) * 0.5;
    float gV = NdotV / (NdotV * (1.0 - k) + k);
    float gL = NdotL / (NdotL * (1.0 - k) + k);
    return gV * gL;
}

// ── Phase 1: BRDF integration LUT ─────────────────────────────────────────────
// Output: RG16F, R = F0 scale (A), G = F0 bias (B).
// Fragment shader uses: F_with_LUT = F0 * brdf.r + brdf.g
kernel void brdf_lut_kernel(
    texture2d<float, access::write> outLUT [[texture(0)]],
    uint2 tid                              [[thread_position_in_grid]]
) {
    uint w = outLUT.get_width();
    uint h = outLUT.get_height();
    if (tid.x >= w || tid.y >= h) return;

    // Texel-centre coords in (0, 1].
    float NdotV     = (float(tid.x) + 0.5) / float(w);
    float roughness = (float(tid.y) + 0.5) / float(h);

    // V in the same tangent frame as importanceSampleGGX (N = +Z).
    float3 V = float3(sqrt(1.0 - NdotV * NdotV), 0.0, NdotV);

    float A = 0.0;
    float B = 0.0;

    const uint NUM_SAMPLES = 1024u;
    for (uint i = 0u; i < NUM_SAMPLES; i++) {
        float2 Xi = hammersley(i, NUM_SAMPLES);
        float3 H  = importanceSampleGGX(Xi, roughness);
        float3 L  = 2.0 * dot(V, H) * H - V;        // reflect(-V, H)

        float NdotL = saturate(L.z);
        float NdotH = saturate(H.z);
        float VdotH = saturate(dot(V, H));

        if (NdotL > 0.0) {
            float G    = G_SmithIBL(NdotV, NdotL, roughness);
            float Gvis = (G * VdotH) / max(NdotH * NdotV, 1e-7);
            float Fc   = pow(1.0 - VdotH, 5.0);
            A += (1.0 - Fc) * Gvis;
            B += Fc * Gvis;
        }
    }
    A /= float(NUM_SAMPLES);
    B /= float(NUM_SAMPLES);

    outLUT.write(float4(A, B, 0.0, 1.0), tid);
}

// ── Cubemap face → world-space direction ─────────────────────────────────────
// Matches the standard glTF / Khronos sample IBL cubemap face convention.
// uv ∈ [-1, 1]; returned vector is non-normalised (caller normalises).
static float3 cubeDirFromFaceUV(uint face, float2 uv) {
    switch (face) {
        case 0:  return float3( 1.0, -uv.y, -uv.x);   // +X
        case 1:  return float3(-1.0, -uv.y,  uv.x);   // -X
        case 2:  return float3( uv.x,  1.0,  uv.y);   // +Y
        case 3:  return float3( uv.x, -1.0, -uv.y);   // -Y
        case 4:  return float3( uv.x, -uv.y,  1.0);   // +Z
        default: return float3(-uv.x, -uv.y, -1.0);   // -Z (case 5)
    }
}

// ── Procedural sky parameters (uniform buffer) ───────────────────────────────
// Hardcoded defaults in Swift for the v1 cubemap; promoted to inspector
// controls in a later phase if you want to tune the env.
struct EnvSkyParams {
    float4 topColor;       // xyz = colour, w unused
    float4 horizonColor;
    float4 bottomColor;
    float4 sunDir;         // xyz = normalised, w unused
    float4 sunColor;       // xyz = colour, w = cos(angularRadius)
};

// Evaluate the procedural sky for a given normalised direction.
static float3 evalProceduralSky(float3 dir, constant EnvSkyParams &p) {
    // Vertical gradient: dir.y in [-1, +1] → t in [0, 1].
    float t = saturate(dir.y * 0.5 + 0.5);
    float3 sky;
    if (t < 0.5) {
        sky = mix(p.bottomColor.rgb, p.horizonColor.rgb, t * 2.0);
    } else {
        sky = mix(p.horizonColor.rgb, p.topColor.rgb, (t - 0.5) * 2.0);
    }
    // Sun: soft disc with smooth edge.
    float cosA   = dot(dir, normalize(p.sunDir.xyz));
    float cosRad = p.sunColor.w;
    if (cosA > cosRad) {
        float falloff = (cosA - cosRad) / max(1.0 - cosRad, 1e-5);
        sky += p.sunColor.rgb * pow(saturate(falloff), 4.0);
    }
    return sky;
}

// ── Phase 2: Procedural environment cubemap ──────────────────────────────────
// Writes one texel per (face, x, y) thread.  Output is RGBA16F so HDR sun
// intensities above 1.0 are preserved through the prefiltering passes.
kernel void env_cube_kernel(
    texturecube<float, access::write> outCube   [[texture(0)]],
    constant EnvSkyParams            &params    [[buffer(0)]],
    uint3 tid                                   [[thread_position_in_grid]]
) {
    uint w = outCube.get_width();
    if (tid.x >= w || tid.y >= w || tid.z >= 6) return;

    // Texel centre in [-1, 1].
    float2 uv = float2((float(tid.x) + 0.5) / float(w) * 2.0 - 1.0,
                        (float(tid.y) + 0.5) / float(w) * 2.0 - 1.0);
    float3 dir = normalize(cubeDirFromFaceUV(tid.z, uv));

    float3 col = evalProceduralSky(dir, params);
    outCube.write(float4(col, 1.0), tid.xy, tid.z);
}

// ── Phase 2b: Equirectangular HDR → cubemap ──────────────────────────────────
// Samples a loaded equirectangular environment (latitude-longitude) into the
// env cubemap.  Direction → (u,v): u from azimuth, v from polar angle, with
// v=0 at the top row (dir.y = +1), matching the "-Y +X" HDR row order.
kernel void equirect_to_cube_kernel(
    texturecube<float, access::write>  outCube  [[texture(0)]],
    texture2d<float, access::sample>   equirect [[texture(1)]],
    uint3 tid                                   [[thread_position_in_grid]]
) {
    uint w = outCube.get_width();
    if (tid.x >= w || tid.y >= w || tid.z >= 6) return;

    float2 uv = float2((float(tid.x) + 0.5) / float(w) * 2.0 - 1.0,
                        (float(tid.y) + 0.5) / float(w) * 2.0 - 1.0);
    float3 dir = normalize(cubeDirFromFaceUV(tid.z, uv));

    float u = atan2(dir.z, dir.x) / (2.0 * M_PI_F) + 0.5;     // azimuth, wraps
    float v = acos(clamp(dir.y, -1.0, 1.0)) / M_PI_F;          // polar, 0=up

    constexpr sampler eqSampler(filter::linear,
                                 s_address::repeat,
                                 t_address::clamp_to_edge);
    float3 col = equirect.sample(eqSampler, float2(u, v)).rgb;
    outCube.write(float4(col, 1.0), tid.xy, tid.z);
}

// ── Phase 3: Diffuse irradiance cubemap ──────────────────────────────────────
// Convolves the env cubemap with a cosine-weighted hemisphere kernel.
// Writes the diffuse contribution directly (already absorbs the 1/π factor),
// so the fragment shader's diffuse-IBL line is just:
//     diffuse_ibl = sample(irradianceCube, N) * albedo * (1 - metallic)
//
// Cosine-weighted importance sampling means each sample's contribution is just
// Li(L); the per-sample cos / pdf factors cancel out.  We average over N.
kernel void irradiance_cube_kernel(
    texturecube<float, access::write>  outIrr   [[texture(0)]],
    texturecube<float, access::sample> envCube  [[texture(1)]],
    uint3 tid                                    [[thread_position_in_grid]]
) {
    uint w = outIrr.get_width();
    if (tid.x >= w || tid.y >= w || tid.z >= 6) return;

    float2 uv = float2((float(tid.x) + 0.5) / float(w) * 2.0 - 1.0,
                        (float(tid.y) + 0.5) / float(w) * 2.0 - 1.0);
    float3 N = normalize(cubeDirFromFaceUV(tid.z, uv));

    // Tangent frame around N.
    float3 up = abs(N.y) < 0.999 ? float3(0.0, 1.0, 0.0) : float3(1.0, 0.0, 0.0);
    float3 T  = normalize(cross(up, N));
    float3 B  = cross(N, T);

    constexpr sampler envSampler(filter::linear,
                                  mip_filter::linear,
                                  address::clamp_to_edge);

    const uint NUM_SAMPLES = 1024u;
    float3 acc = float3(0.0);
    for (uint i = 0u; i < NUM_SAMPLES; i++) {
        float2 Xi   = hammersley(i, NUM_SAMPLES);
        float  phi  = 2.0 * M_PI_F * Xi.x;
        float  r    = sqrt(Xi.y);
        float  sinT = r;
        float  cosT = sqrt(max(0.0, 1.0 - r * r));
        float3 local = float3(cos(phi) * sinT, sin(phi) * sinT, cosT);
        float3 L     = local.x * T + local.y * B + local.z * N;
        acc += envCube.sample(envSampler, L).rgb;
    }
    acc *= (1.0 / float(NUM_SAMPLES));
    outIrr.write(float4(acc, 1.0), tid.xy, tid.z);
}

// ── Phase 4: Prefiltered specular cubemap ────────────────────────────────────
// One dispatch per mip level — the Swift side creates a texture view of the
// destination mip and passes the matching roughness via `params.x`.  Uses the
// Karis split-sum approximation (V = N), with samples weighted by NdotL.
struct PrefilterParams {
    float4 params;   // x = roughness, yzw unused
};

kernel void prefilter_cube_kernel(
    texturecube<float, access::write>  outCube  [[texture(0)]],
    texturecube<float, access::sample> envCube  [[texture(1)]],
    constant PrefilterParams          &p        [[buffer(0)]],
    uint3 tid                                    [[thread_position_in_grid]]
) {
    uint w = outCube.get_width();
    if (tid.x >= w || tid.y >= w || tid.z >= 6) return;

    float2 uv = float2((float(tid.x) + 0.5) / float(w) * 2.0 - 1.0,
                        (float(tid.y) + 0.5) / float(w) * 2.0 - 1.0);
    float3 N = normalize(cubeDirFromFaceUV(tid.z, uv));
    float3 V = N;                                        // Karis: V == N == R

    float roughness = max(p.params.x, 0.04);

    // Tangent frame.
    float3 up = abs(N.y) < 0.999 ? float3(0.0, 1.0, 0.0) : float3(1.0, 0.0, 0.0);
    float3 T  = normalize(cross(up, N));
    float3 B  = cross(N, T);

    constexpr sampler envSampler(filter::linear,
                                  mip_filter::linear,
                                  address::clamp_to_edge);

    float3 acc        = float3(0.0);
    float  totalW     = 0.0;

    const uint NUM_SAMPLES = 1024u;
    for (uint i = 0u; i < NUM_SAMPLES; i++) {
        float2 Xi = hammersley(i, NUM_SAMPLES);
        float3 Hl = importanceSampleGGX(Xi, roughness);
        float3 H  = Hl.x * T + Hl.y * B + Hl.z * N;
        float3 L  = 2.0 * dot(V, H) * H - V;             // reflect(-V, H)
        float  NdotL = saturate(dot(N, L));
        if (NdotL > 0.0) {
            acc    += envCube.sample(envSampler, L).rgb * NdotL;
            totalW += NdotL;
        }
    }
    acc *= 1.0 / max(totalW, 1e-4);
    outCube.write(float4(acc, 1.0), tid.xy, tid.z);
}
