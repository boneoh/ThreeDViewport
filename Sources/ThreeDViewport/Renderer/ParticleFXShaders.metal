#include <metal_stdlib>
using namespace metal;

// Procedural weather particles (rain / snow / sleet).
//
// Each particle's position is a closed-form function of its static seed and the
// `time` uniform — no per-frame simulation state — so preview, scrubbing, and
// export all produce identical results.  Drawn as instanced camera-facing
// billboards, stretched along the fall direction for streaks (rain / sleet).

struct ParticleFXUniforms {
    float4x4 viewProjection;
    float4   cameraRight;
    float4   cameraUp;
    float4   emitterCenter;
    float4   emitterSize;
    float4   color;
    float    time;
    float    fallSpeed;
    float    particleSize;
    float    streak;
    float    sway;
    float    swayFreq;
    uint     colorMode;
    uint     mode;        // 0 = falling weather, 1 = smoke
    float    growth;      // smoke: size growth over lifetime
    float    lifetime;    // smoke: particle lifetime (seconds)
    float    baseAlpha;   // per-particle base alpha
    float    _pad;
};

struct ParticleVOut {
    float4 position [[position]];
    float2 uv;       // -1..1 within the billboard, for soft falloff
    float  alpha;    // edge fade
};

// Cheap deterministic per-particle hash.
static float hash11(float n) { return fract(sin(n) * 43758.5453123); }

vertex ParticleVOut particlefx_vertex(uint vid  [[vertex_id]],
                                      uint iid  [[instance_id]],
                                      constant float4            *seeds [[buffer(0)]],
                                      constant ParticleFXUniforms &u    [[buffer(1)]])
{
    float4 seed = seeds[iid];                 // xyz in [0,1], w = phase
    float3 sz   = u.emitterSize.xyz;

    float  sizeVar   = 0.7 + 0.6 * hash11(float(iid) + 1.0);
    float3 local;
    float  sizeScale;   // billboard size multiplier (smoke grows with age)
    float  pAlpha;      // final per-particle alpha

    if (u.mode == 1u) {
        // ── Smoke: rise, spread, grow, and fade over a per-particle lifetime ──
        // The lifecycle is a closed-form function of (seed.w, time): each puff is
        // born near the bottom-centre, rises to the top over its lifetime, widens
        // in a cone with turbulence that grows with age (billowing), grows in
        // size, and fades in then out — so preview, scrub, and export agree.
        float L   = max(u.lifetime, 0.1) * (0.6 + 0.8 * hash11(float(iid) + 7.0));
        float age = fmod(u.time + seed.w * L, L);
        float a   = age / L;                                 // 0 (born) → 1 (gone)

        float spread = 0.15 + 0.85 * a;                      // conical widening
        float ph     = seed.w * 6.2831853;
        float turbX  = u.sway * a * sin(u.time * u.swayFreq       + ph);
        float turbZ  = u.sway * a * cos(u.time * u.swayFreq * 0.8 + ph * 1.7);

        local = float3((seed.x - 0.5) * sz.x * 0.5 * spread + turbX,
                       (a - 0.5) * sz.y,                     // bottom → top
                       (seed.z - 0.5) * sz.z * 0.5 * spread + turbZ);

        sizeScale  = 0.4 + u.growth * a;                     // grow as it rises
        float fade = smoothstep(0.0, 0.18, a) * (1.0 - smoothstep(0.55, 1.0, a));
        pAlpha     = fade * u.baseAlpha;
    } else {
        // ── Falling weather: y cycles top→bottom over time and wraps ──────────
        float cyclesPerSec = (sz.y > 1e-4) ? (u.fallSpeed / sz.y) : 0.0;
        float yProg  = fract(seed.y + u.time * cyclesPerSec); // 0 (top) → 1 (wrap)
        float yLocal = 1.0 - yProg;                           // 1 = top, 0 = bottom

        // Lateral turbulence (sway).
        float ph    = seed.w * 6.2831853;
        float swayX = u.sway * sin(u.time * u.swayFreq        + ph);
        float swayZ = u.sway * cos(u.time * u.swayFreq * 0.8  + ph * 1.7);

        local = float3((seed.x - 0.5) * sz.x + swayX,
                       (yLocal - 0.5) * sz.y,
                       (seed.z - 0.5) * sz.z + swayZ);

        sizeScale = 1.0;
        // Fade in at the top and out at the bottom so wrapping doesn't pop.
        float edgeFade = smoothstep(0.0, 0.06, yProg) * (1.0 - smoothstep(0.94, 1.0, yProg));
        pAlpha = edgeFade * u.baseAlpha;
    }

    float3 worldPos = u.emitterCenter.xyz + local;

    // ── Billboard ─────────────────────────────────────────────────────────────
    float halfW = u.particleSize * sizeVar * sizeScale;
    float halfL = halfW * u.streak;

    // Streak axis = world fall direction (down) projected into the camera plane.
    float3 fallDir = float3(0.0, -1.0, 0.0);
    float2 d = float2(dot(fallDir, u.cameraRight.xyz), dot(fallDir, u.cameraUp.xyz));
    d = (length(d) < 1e-4) ? float2(0.0, -1.0) : normalize(d);
    float2 perp = float2(-d.y, d.x);

    const float2 corners[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
    float2 c = corners[vid];
    float2 offset2D = perp * (c.x * halfW) + d * (c.y * halfL);
    float3 cornerWorld = worldPos
                       + u.cameraRight.xyz * offset2D.x
                       + u.cameraUp.xyz    * offset2D.y;

    ParticleVOut out;
    out.position = u.viewProjection * float4(cornerWorld, 1.0);
    out.uv       = c;
    out.alpha    = pAlpha;
    return out;
}

fragment float4 particlefx_fragment(ParticleVOut in [[stage_in]],
                                    constant ParticleFXUniforms &u [[buffer(1)]])
{
    float a = saturate(1.0 - length(in.uv)) * in.alpha;   // soft falloff
    if (a < 0.003) discard_fragment();
    float3 col = (u.colorMode == 2u) ? float3(1.0) : u.color.xyz;
    return float4(col, a);   // straight alpha (source-over blend)
}
