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
