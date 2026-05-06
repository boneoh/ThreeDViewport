#include <metal_stdlib>
using namespace metal;

// ── Laser beam billboard shader ───────────────────────────────────────────────
//
// Renders a camera-facing billboard quad along the beam axis.  The quad is
// built entirely in the vertex shader from four procedural vertex IDs:
//
//   vid 0 → near end, left edge
//   vid 1 → near end, right edge
//   vid 2 → far end,  left edge
//   vid 3 → far end,  right edge
//
// "Left" and "right" are perpendicular to the projected beam axis in pixel
// space, giving consistent pixel-width appearance regardless of view angle.
//
// The fragment outputs an additive Gaussian glow across the beam width.
// The render pipeline uses additive RGB blending so the beam brightens
// whatever is behind it; destination alpha is preserved (content mask intact).

// ── Uniform block — must match Swift LaserBeamUniforms in ShaderTypes.swift ──

struct LaserBeamUniforms {
    float4x4 viewProjectionMatrix;  // 64 bytes
    float4   startWorld;            // 16  xyz = beam origin (w = 1)
    float4   endWorld;              // 16  xyz = beam tip    (w = 1)
    float4   color;                 // 16  xyz = linear RGB  (w = unused)
    float2   screenSize;            // 8   drawable size in pixels
    float    thickness;             // 4   beam width in pixels
    float    pad;                   // 4
};  // total: 128 bytes

struct LaserVOut {
    float4 position [[position]];
    float3 color;
    float  crossT;      // −1 (left edge) … +1 (right edge) for Gaussian glow
};

// ── Vertex shader ─────────────────────────────────────────────────────────────

vertex LaserVOut laser_beam_vertex(
    uint                        vid [[vertex_id]],
    constant LaserBeamUniforms &u   [[buffer(0)]]
) {
    bool  isEnd = (vid >= 2u);
    float side  = ((vid & 1u) == 0u) ? -1.0f : 1.0f;

    // Project both beam endpoints to clip space
    float4 sc = u.viewProjectionMatrix * u.startWorld;
    float4 ec = u.viewProjectionMatrix * u.endWorld;

    // Perspective-divide to NDC (Metal NDC: x ∈ [−1,1], y ∈ [−1,1] bottom-up)
    float2 sNDC = sc.xy / sc.w;
    float2 eNDC = ec.xy / ec.w;

    // Convert to pixel space for stable direction/perp calculation
    //   (0,0) = bottom-left, (W,H) = top-right  — direction-only, sign doesn't matter
    float2 sPx = (sNDC * 0.5f + 0.5f) * u.screenSize;
    float2 ePx = (eNDC * 0.5f + 0.5f) * u.screenSize;

    // Beam axis direction in pixel space (normalised)
    float2 dir = ePx - sPx;
    float  len = length(dir);
    dir = (len > 0.1f) ? dir / len : float2(1.0f, 0.0f);

    // Perpendicular: rotate 90° CCW in pixel space
    float2 perp = float2(-dir.y, dir.x);

    // Current vertex: endpoint pixel position + half-thickness offset
    float2 px = (isEnd ? ePx : sPx) + perp * (side * u.thickness * 0.5f);

    // Convert back to NDC and into clip space (preserving original w for depth)
    float2 ndc = (px / u.screenSize) * 2.0f - 1.0f;
    float  w   = isEnd ? ec.w : sc.w;
    float  z   = isEnd ? ec.z : sc.z;

    LaserVOut out;
    out.position = float4(ndc * w, z, w);
    out.color    = u.color.rgb;
    out.crossT   = side;
    return out;
}

// ── Fragment shader ───────────────────────────────────────────────────────────

fragment float4 laser_beam_fragment(LaserVOut in [[stage_in]]) {
    // Gaussian glow: full brightness at centre, fades to ~0 at edges
    float  t    = in.crossT;                        // −1 … +1
    float  glow = exp(-3.5f * t * t);

    // Gamma-encode the linear beam colour to match the bgra8Unorm render target
    float3 col  = pow(saturate(in.color) * glow, float3(1.0f / 2.2f));

    // Alpha = glow so the additive blend feathers naturally at edges
    return float4(col, glow);
}

// ═════════════════════════════════════════════════════════════════════════════
// Laser hit effect — star flare + surface ring (additive, no depth write)
// ═════════════════════════════════════════════════════════════════════════════
//
// A single screen-space billboard quad is expanded in pixel space from the
// projected hit point.  The fragment combines:
//   • Tight Gaussian core + wider corona glow
//   • 4-point star rays (fast pulse ≈11 Hz)
//   • Smoothstep annulus ring (slow pulse ≈4.5 Hz)
//
// Depth bias (clip.z − 0.001·clip.w) lifts the billboard just above the
// surface so the depth test passes without z-fighting.

struct LaserHitUniforms {
    float4x4 viewProjectionMatrix;   // 64
    float4   hitPoint;               // 16  xyz = world pos, w = 1
    float4   color;                  // 16  rgb = laser colour
    float2   screenSize;             //  8  drawable pixels
    float    hitRadius;              //  4  billboard half-size in pixels
    float    time;                   //  4  seconds
};  // total: 112

struct LaserHitVOut {
    float4 position [[position]];
    float2 uv;      // −1…+1 from billboard centre
    float3 color;
    float  time;
};

vertex LaserHitVOut laser_hit_vertex(
    uint                       vid [[vertex_id]],
    constant LaserHitUniforms &u   [[buffer(0)]]
) {
    // Corner offsets: vid 0=(−1,−1)  1=(+1,−1)  2=(−1,+1)  3=(+1,+1)
    float2 uv = float2((vid & 1u) ? 1.0f : -1.0f,
                       (vid & 2u) ? 1.0f : -1.0f);

    // Project hit point to clip space
    float4 clip = u.viewProjectionMatrix * u.hitPoint;

    // Depth bias: pull slightly toward camera to avoid z-fighting at surface
    clip.z -= 0.001f * clip.w;

    // Expand billboard in pixel space for stable size regardless of distance
    float2 ndc = clip.xy / clip.w;
    float2 px  = (ndc * 0.5f + 0.5f) * u.screenSize;
    px  += uv * u.hitRadius;
    ndc  = (px / u.screenSize) * 2.0f - 1.0f;

    LaserHitVOut out;
    out.position = float4(ndc * clip.w, clip.z, clip.w);
    out.uv       = uv;
    out.color    = u.color.rgb;
    out.time     = u.time;
    return out;
}

fragment float4 laser_hit_fragment(LaserHitVOut in [[stage_in]]) {
    float2 uv = in.uv;
    float  r  = length(uv);

    // Clip to a circle — no square outline at quad corners
    if (r > 1.0f) discard_fragment();

    float angle = atan2(uv.y, uv.x);

    // Pulse ≈11 Hz  (11 × 2π ≈ 69.115)
    float pulse = 0.6f + 0.4f * sin(in.time * 69.115f);

    // Tight Gaussian core
    float core = exp(-12.0f * r * r);

    // 4-point star rays
    float star = pow(abs(cos(2.0f * angle)), 5.0f) * exp(-5.0f * r * r);

    float total = saturate((core + 0.8f * star) * pulse);

    // Discard near-zero pixels
    if (total < 0.004f) discard_fragment();

    // Gamma-encode to match bgra8Unorm render target
    float3 col = pow(saturate(in.color * total), float3(1.0f / 2.2f));
    return float4(col, total);
}

// ═════════════════════════════════════════════════════════════════════════════
// Spark particle billboards — instanced, one quad per particle
// ═════════════════════════════════════════════════════════════════════════════
//
// [[instance_id]] selects which particle from the buffer.
// [[vertex_id]]   selects which of the four quad corners.
// The billboard is built in world space using camera right/up vectors.

struct SparkParticleGPU {
    float4 position;   // 16  xyz = world pos
    float4 color;      // 16  rgb = colour
    float  size;       //  4  world-unit billboard half-extent
    float  alpha;      //  4  0–1 fade
    float2 pad;        //  8
};  // total: 48

struct SparkUniforms {
    float4x4 viewProjectionMatrix;   // 64
    float4   cameraRight;            // 16
    float4   cameraUp;               // 16
};  // total: 96

struct SparkVOut {
    float4 position [[position]];
    float2 uv;
    float3 color;
    float  alpha;
};

vertex SparkVOut spark_vertex(
    uint                       vid        [[vertex_id]],
    uint                       iid        [[instance_id]],
    constant SparkParticleGPU *particles  [[buffer(0)]],
    constant SparkUniforms    &u          [[buffer(1)]]
) {
    float2 corner = float2((vid & 1u) ? 1.0f : -1.0f,
                           (vid & 2u) ? 1.0f : -1.0f);

    SparkParticleGPU p = particles[iid];

    // Camera-facing billboard in world space
    float3 worldPos = p.position.xyz
                    + u.cameraRight.xyz * (corner.x * p.size)
                    + u.cameraUp.xyz    * (corner.y * p.size);

    SparkVOut out;
    out.position = u.viewProjectionMatrix * float4(worldPos, 1.0f);
    out.uv       = corner;
    out.color    = p.color.rgb;
    out.alpha    = p.alpha;
    return out;
}

fragment float4 spark_fragment(SparkVOut in [[stage_in]]) {
    float r    = length(in.uv);
    float glow = exp(-5.0f * r * r) * in.alpha;
    float3 col = pow(saturate(in.color * glow), float3(1.0f / 2.2f));
    return float4(col, glow);
}
