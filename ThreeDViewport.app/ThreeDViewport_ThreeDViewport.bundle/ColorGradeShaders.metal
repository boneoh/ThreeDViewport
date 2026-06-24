#include <metal_stdlib>
using namespace metal;

// ── Color Grade post-process ──────────────────────────────────────────────────
// Full-screen pass that samples the rendered frame from `src` and writes
// brightness/contrast/gamma-adjusted pixels to the render target.
//
// Applied as the very last pass before present (or before staging blit in
// VideoExporter) so it affects the complete composited image.
//
// params: float3  .x = brightness addend        (range −1 … +1, identity = 0)
//                 .y = contrast multiplier       (range  0 … 3,  identity = 1)
//                 .z = gamma exponent (= 1/γ)    (precomputed; identity when γ=1 → .z=1)
//
// Operation order (applied in linear display space):
//   1. Brightness: uniform addition to each channel.
//   2. Contrast:   scale around the 0.5 midpoint — (c − 0.5) × contrast + 0.5.
//   3. Gamma:      power curve — pow(max(c,0), 1/γ).
//                  Intuitive convention: γ > 1 lifts midtones (brighter),
//                  γ < 1 darkens midtones.  Precomputing 1/γ on the CPU avoids
//                  a per-pixel reciprocal in the shader.
// Result is clamped to [0,1].

struct GradeVertOut {
    float4 position [[position]];
    float2 uv;
};

// Outputs a full-screen triangle-strip quad.
// UV (0,0) = top-left, (1,1) = bottom-right — matches Metal's texture origin.
vertex GradeVertOut color_grade_vertex(uint vid [[vertex_id]]) {
    const float2 pos[4] = { {-1.0, -1.0}, {1.0, -1.0}, {-1.0, 1.0}, {1.0, 1.0} };
    const float2 uvs[4] = { {0.0,  1.0},  {1.0,  1.0}, {0.0, 0.0},  {1.0, 0.0} };
    GradeVertOut out;
    out.position = float4(pos[vid], 0.0, 1.0);
    out.uv       = uvs[vid];
    return out;
}

fragment float4 color_grade_fragment(
    GradeVertOut        in     [[stage_in]],
    texture2d<float>    src    [[texture(0)]],
    constant float3    &params [[buffer(0)]]   // x=brightness, y=contrast, z=1/gamma
) {
    constexpr sampler s(filter::nearest, address::clamp_to_edge);
    float4 pix  = src.sample(s, in.uv);
    float3 rgb  = pix.rgb;

    // 1. Brightness: shift all channels uniformly
    rgb += params.x;

    // 2. Contrast: scale around the perceptual midpoint
    rgb = (rgb - 0.5) * params.y + 0.5;

    // 3. Gamma: power curve (clamp to zero first to avoid undefined pow(negative))
    rgb = pow(max(rgb, 0.0), params.z);

    return float4(saturate(rgb), pix.a);
}

// ── FXAA (Fast approXimate Anti-Aliasing) ──────────────────────────────────────
// Edge-aware post-process AA on the final composited LDR image (Lottes-style compact
// variant).  Finds edges via luma contrast among a 5-tap neighbourhood and blends
// along the edge direction; flat interiors early-out so they stay crisp.  Reuses the
// full-screen `color_grade_vertex`.  `invRes` = 1 / (width, height) in pixels.

constant float FXAA_SPAN_MAX   = 8.0;
constant float FXAA_REDUCE_MUL = 1.0 / 8.0;
constant float FXAA_REDUCE_MIN = 1.0 / 128.0;

static inline float fxaaLuma(float3 rgb) {
    return dot(rgb, float3(0.299, 0.587, 0.114));
}

fragment float4 fxaa_fragment(
    GradeVertOut        in     [[stage_in]],
    texture2d<float>    src    [[texture(0)]],
    constant float2    &invRes [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = in.uv;

    float3 rgbM  = src.sample(s, uv).rgb;
    float3 rgbNW = src.sample(s, uv + float2(-1.0, -1.0) * invRes).rgb;
    float3 rgbNE = src.sample(s, uv + float2( 1.0, -1.0) * invRes).rgb;
    float3 rgbSW = src.sample(s, uv + float2(-1.0,  1.0) * invRes).rgb;
    float3 rgbSE = src.sample(s, uv + float2( 1.0,  1.0) * invRes).rgb;

    float lumaM  = fxaaLuma(rgbM);
    float lumaNW = fxaaLuma(rgbNW);
    float lumaNE = fxaaLuma(rgbNE);
    float lumaSW = fxaaLuma(rgbSW);
    float lumaSE = fxaaLuma(rgbSE);

    float lumaMin = min(lumaM, min(min(lumaNW, lumaNE), min(lumaSW, lumaSE)));
    float lumaMax = max(lumaM, max(max(lumaNW, lumaNE), max(lumaSW, lumaSE)));

    // Flat region → no edge → leave the pixel untouched (keeps interiors sharp).
    if (lumaMax - lumaMin < lumaMax * 0.125 + 0.02) {
        return float4(rgbM, 1.0);
    }

    // Edge direction (perpendicular to the luma gradient).
    float2 dir;
    dir.x = -((lumaNW + lumaNE) - (lumaSW + lumaSE));
    dir.y =  ((lumaNW + lumaSW) - (lumaNE + lumaSE));

    float dirReduce = max((lumaNW + lumaNE + lumaSW + lumaSE) * 0.25 * FXAA_REDUCE_MUL,
                          FXAA_REDUCE_MIN);
    float rcpDirMin = 1.0 / (min(abs(dir.x), abs(dir.y)) + dirReduce);
    dir = clamp(dir * rcpDirMin, -FXAA_SPAN_MAX, FXAA_SPAN_MAX) * invRes;

    float3 rgbA = 0.5 * (src.sample(s, uv + dir * (1.0/3.0 - 0.5)).rgb +
                         src.sample(s, uv + dir * (2.0/3.0 - 0.5)).rgb);
    float3 rgbB = rgbA * 0.5 + 0.25 * (src.sample(s, uv + dir * -0.5).rgb +
                                       src.sample(s, uv + dir *  0.5).rgb);

    float lumaB = fxaaLuma(rgbB);
    // If the wider tap overshoots the local range, fall back to the narrow blend.
    if (lumaB < lumaMin || lumaB > lumaMax) {
        return float4(rgbA, 1.0);
    }
    return float4(rgbB, 1.0);
}

// ── Luma-alpha pass ────────────────────────────────────────────────────────────
// Copies RGB unchanged and writes alpha = Rec.709 luma of the RGB.  Used by
// VideoExporter for ProRes 4444 color passes so the alpha channel carries a luma
// matte.  The pixel buffer is tagged Premultiplied downstream, so the full RGB
// displays at correct brightness while the luma sits in alpha as a key.
fragment float4 luma_alpha_fragment(
    GradeVertOut        in  [[stage_in]],
    texture2d<float>    src [[texture(0)]]
) {
    constexpr sampler s(filter::nearest, address::clamp_to_edge);
    float4 pix  = src.sample(s, in.uv);
    float  luma = dot(pix.rgb, float3(0.2126, 0.7152, 0.0722));
    return float4(pix.rgb, luma);
}
