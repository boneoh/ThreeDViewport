#include <metal_stdlib>
using namespace metal;

// Raymarched fog volume.
//
// A fullscreen pass that marches each camera ray through an axis-aligned box
// (clamped to scene depth), accumulating density with a soft edge falloff, and
// outputs fog colour + alpha for source-over blending over the already-rendered
// scene.  It reads ONLY the scene depth texture — the scene colour stays in the
// destination and is combined by hardware blending — so it composites the same
// way over the live drawable and the exporter's colour texture, with no
// read-after-write.  Flat-coloured (no light scattering); depth-occluded by the
// scene.  Black + White matte mode leaves the matte untouched.

struct FogVolumeUniforms {
    float4x4 inverseViewProjection;
    float4   cameraPos;   // xyz = world eye position
    float4   boxMin;      // xyz = volume min corner
    float4   boxMax;      // xyz = volume max corner
    float4   color;       // rgb = display-space fog colour
    float    density;     // overall opacity / extinction
    float    variance;    // 0 = hard box, 1 = density fades fully toward the faces
    uint     colorMode;   // 0 = greyscale, 1 = color, 2 = black+white matte
    uint     steps;       // raymarch step count (quality)
};

struct FogVOut {
    float4 position [[position]];
    float2 ndc;            // clip-space xy in [-1,1], y up
};

vertex FogVOut fogvolume_vertex(uint vid [[vertex_id]]) {
    // Single oversized triangle covering the screen.
    float2 p[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    FogVOut out;
    out.position = float4(p[vid], 0.0, 1.0);
    out.ndc      = p[vid];
    return out;
}

// Ray / AABB slab intersection.  Returns (tNear, tFar) in ray-length units along
// the normalized `dir`; the ray hits the box when tNear < tFar.
static float2 intersectBox(float3 ro, float3 dir, float3 bmin, float3 bmax) {
    float3 inv    = 1.0 / dir;
    float3 t0     = (bmin - ro) * inv;
    float3 t1     = (bmax - ro) * inv;
    float3 tsmall = min(t0, t1);
    float3 tbig   = max(t0, t1);
    float  tNear  = max(max(tsmall.x, tsmall.y), tsmall.z);
    float  tFar   = min(min(tbig.x,  tbig.y),  tbig.z);
    return float2(tNear, tFar);
}

fragment float4 fogvolume_fragment(FogVOut in [[stage_in]],
                                   constant FogVolumeUniforms &u [[buffer(0)]],
                                   texture2d<float> sceneDepth   [[texture(0)]])
{
    // Black + White matte: fog renders as solid white below (for FX mattes), so
    // no early discard here — the colour branch handles the white output.
    constexpr sampler depthSampler(filter::nearest, address::clamp_to_edge);

    // Scene depth at this pixel (uv origin top-left, y down).  Nearest sampling
    // by normalized uv tolerates a depth texture that differs in size from the
    // destination (e.g. capped feedback depth vs a Retina drawable).
    float2 uv = float2((in.ndc.x + 1.0) * 0.5, (1.0 - in.ndc.y) * 0.5);
    float  d  = sceneDepth.sample(depthSampler, uv).r;   // [0,1]; 1 = far / cleared

    // Reconstruct the camera ray and the scene hit distance from the inverse VP.
    float4 farClip = u.inverseViewProjection * float4(in.ndc, 1.0, 1.0);
    float3 ro      = u.cameraPos.xyz;
    float3 dir     = normalize(farClip.xyz / farClip.w - ro);

    float4 hitClip   = u.inverseViewProjection * float4(in.ndc, d, 1.0);
    float  sceneDist = length(hitClip.xyz / hitClip.w - ro);

    float2 tb    = intersectBox(ro, dir, u.boxMin.xyz, u.boxMax.xyz);
    float  tNear = max(tb.x, 0.0);
    float  tFar  = min(tb.y, sceneDist);
    if (tFar <= tNear) discard_fragment();

    // March from entry to the clamped exit, accumulating optical depth weighted
    // by a soft edge falloff (density fades toward the box faces as variance →1).
    int    steps   = int(max(4u, u.steps));                 // quality (clamped)
    float3 center  = (u.boxMin.xyz + u.boxMax.xyz) * 0.5;
    float3 halfExt = max((u.boxMax.xyz - u.boxMin.xyz) * 0.5, float3(1e-4));
    float  stepLen = (tFar - tNear) / float(steps);
    float  edge0   = clamp(1.0 - u.variance, 0.0, 0.999);   // falloff onset (normalised)

    float od = 0.0;
    for (int i = 0; i < steps; ++i) {
        float  t = tNear + (float(i) + 0.5) * stepLen;
        float3 q = abs(ro + dir * t - center) / halfExt;    // 0 centre → 1 face
        float  fall = (1.0 - smoothstep(edge0, 1.0, q.x))
                    * (1.0 - smoothstep(edge0, 1.0, q.y))
                    * (1.0 - smoothstep(edge0, 1.0, q.z));
        od += fall * stepLen;
    }

    float alpha = 1.0 - exp(-u.density * od);
    if (alpha < 0.003) discard_fragment();

    float3 col = u.color.xyz;
    if (u.colorMode == 2u) {                 // black+white matte: solid white fog
        col = float3(1.0);
    } else if (u.colorMode == 0u) {          // greyscale: match the desaturated scene
        col = float3(dot(col, float3(0.2126, 0.7152, 0.0722)));
    }
    return float4(col, alpha);   // straight alpha → source-over blend
}
