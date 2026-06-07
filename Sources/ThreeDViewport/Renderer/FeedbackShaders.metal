#include <metal_stdlib>
using namespace metal;

// ── Shared vertex output ──────────────────────────────────────────────────────

struct FbQuadOut {
    float4 position [[position]];
    float2 uv;
};

// Generates a full-screen triangle strip from four procedural vertices.
vertex FbQuadOut feedback_vertex(uint vid [[vertex_id]]) {
    constexpr float2 pos[4] = {
        float2(-1.0, -1.0), float2(-1.0,  1.0),
        float2( 1.0, -1.0), float2( 1.0,  1.0)
    };
    constexpr float2 uvs[4] = {
        float2(0.0, 1.0), float2(0.0, 0.0),
        float2(1.0, 1.0), float2(1.0, 0.0)
    };
    FbQuadOut out;
    out.position = float4(pos[vid], 0.0, 1.0);
    out.uv       = uvs[vid];
    return out;
}

// ── Blend-mode uniform (matches Swift FeedbackUniforms layout exactly) ────────

struct FeedbackUniforms {
    float decay;             // 0=pure scene, 1=full blend result
    uint  blendMode;         // BlendMode raw value (0=normal … 23=luminosity)
    uint  swapLayers;        // 0=scene on top, 1=feedback on top
    uint  excludeBackground; // 1=foreground-only premultiplied (bg drawn fresh behind)
};

// ── HSL helpers (Rec.709 luminance) ─────────────────────────────────────────

static float  lum(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

static float3 clipColor(float3 c) {
    float l = lum(c);
    float n = min(c.r, min(c.g, c.b));
    float x = max(c.r, max(c.g, c.b));
    if (n < 0.0) c = l + (c - l) * l / (l - n);
    if (x > 1.0) c = l + (c - l) * (1.0 - l) / (x - l);
    return c;
}

static float3 setLum(float3 c, float l)  { return clipColor(c + (l - lum(c))); }
static float  sat(float3 c)              { return max(c.r,max(c.g,c.b)) - min(c.r,min(c.g,c.b)); }

// setSat: linearly maps [cmin,cmax] → [0,s], preserving relative positions.
static float3 setSat(float3 c, float s) {
    float cmin = min(c.r, min(c.g, c.b));
    float cmax = max(c.r, max(c.g, c.b));
    return (cmax > cmin) ? (c - cmin) * s / (cmax - cmin) : float3(0.0);
}

// ── Per-component soft-light helper (W3C formula) ────────────────────────────

static float softLightCh(float s, float d) {
    if (s <= 0.5) {
        return d - (1.0 - 2.0*s) * d * (1.0 - d);
    } else {
        float dd = (d <= 0.25) ? ((16.0*d - 12.0)*d + 4.0)*d : sqrt(d);
        return d + (2.0*s - 1.0) * (dd - d);
    }
}

// ── Core blend function ───────────────────────────────────────────────────────
// fg = foreground (top layer), bg = background (bottom layer).
// Returns the blended RGB; alpha is handled separately.

static float3 applyBlend(float3 fg, float3 bg, uint mode) {
    float3 r;
    switch (mode) {

    // ── 0  Normal ─────────────────────────────────────────────────────────────
    default:
    case 0:  r = fg; break;

    // ── Darkening ─────────────────────────────────────────────────────────────
    case 1:  // Multiply
        r = fg * bg;
        break;
    case 2:  // Darken
        r = min(fg, bg);
        break;
    case 3:  // Color Burn   1 - (1-bg)/fg
        r = 1.0 - clamp((1.0 - bg) / max(fg, 1e-5), 0.0, 1.0);
        break;
    case 4:  // Linear Burn  fg+bg-1
        r = clamp(fg + bg - 1.0, 0.0, 1.0);
        break;

    // ── Lightening ────────────────────────────────────────────────────────────
    case 5:  // Screen       1-(1-fg)(1-bg)
        r = 1.0 - (1.0 - fg) * (1.0 - bg);
        break;
    case 6:  // Lighten
        r = max(fg, bg);
        break;
    case 7:  // Color Dodge  bg/(1-fg)
        r = clamp(bg / max(1.0 - fg, 1e-5), 0.0, 1.0);
        break;
    case 8:  // Linear Dodge (Add)
        r = clamp(fg + bg, 0.0, 1.0);
        break;

    // ── Contrast ──────────────────────────────────────────────────────────────
    case 9:  // Overlay  — fg controls the curve, bg is the base
        r = float3(
            fg.r <= 0.5 ? 2.0*fg.r*bg.r : 1.0-2.0*(1.0-fg.r)*(1.0-bg.r),
            fg.g <= 0.5 ? 2.0*fg.g*bg.g : 1.0-2.0*(1.0-fg.g)*(1.0-bg.g),
            fg.b <= 0.5 ? 2.0*fg.b*bg.b : 1.0-2.0*(1.0-fg.b)*(1.0-bg.b));
        break;
    case 10: // Soft Light
        r = float3(softLightCh(fg.r,bg.r),
                   softLightCh(fg.g,bg.g),
                   softLightCh(fg.b,bg.b));
        break;
    case 11: // Hard Light  — swap roles vs Overlay
        r = float3(
            bg.r <= 0.5 ? 2.0*fg.r*bg.r : 1.0-2.0*(1.0-fg.r)*(1.0-bg.r),
            bg.g <= 0.5 ? 2.0*fg.g*bg.g : 1.0-2.0*(1.0-fg.g)*(1.0-bg.g),
            bg.b <= 0.5 ? 2.0*fg.b*bg.b : 1.0-2.0*(1.0-fg.b)*(1.0-bg.b));
        break;
    case 12: // Vivid Light   burn(2fg,bg) if fg≤0.5 else dodge(2fg-1,bg)
        r = float3(
            fg.r <= 0.5
                ? 1.0-clamp((1.0-bg.r)/max(2.0*fg.r,1e-5),0.0,1.0)
                : clamp(bg.r/max(2.0*(1.0-fg.r),1e-5),0.0,1.0),
            fg.g <= 0.5
                ? 1.0-clamp((1.0-bg.g)/max(2.0*fg.g,1e-5),0.0,1.0)
                : clamp(bg.g/max(2.0*(1.0-fg.g),1e-5),0.0,1.0),
            fg.b <= 0.5
                ? 1.0-clamp((1.0-bg.b)/max(2.0*fg.b,1e-5),0.0,1.0)
                : clamp(bg.b/max(2.0*(1.0-fg.b),1e-5),0.0,1.0));
        break;
    case 13: // Linear Light  bg + 2fg - 1
        r = clamp(bg + 2.0*fg - 1.0, 0.0, 1.0);
        break;
    case 14: // Pin Light     clamp(bg, 2fg-1, 2fg)
        r = min(max(bg, 2.0*fg - 1.0), 2.0*fg);
        break;
    case 15: // Hard Mix      step(1, fg+bg)
        r = step(float3(1.0), fg + bg);
        break;

    // ── Difference ────────────────────────────────────────────────────────────
    case 16: // Difference
        r = abs(fg - bg);
        break;
    case 17: // Exclusion     fg+bg - 2fg·bg
        r = fg + bg - 2.0*fg*bg;
        break;
    case 18: // Subtract      bg - fg
        r = clamp(bg - fg, 0.0, 1.0);
        break;
    case 19: // Divide        bg/fg
        r = clamp(bg / max(fg, 1e-5), 0.0, 1.0);
        break;

    // ── Component (HSL) ───────────────────────────────────────────────────────
    case 20: // Hue       — fg hue, bg sat+lum
        r = setLum(setSat(fg, sat(bg)), lum(bg));
        break;
    case 21: // Saturation — bg hue, fg sat, bg lum
        r = setLum(setSat(bg, sat(fg)), lum(bg));
        break;
    case 22: // Color     — fg hue+sat, bg lum
        r = setLum(fg, lum(bg));
        break;
    case 23: // Luminosity — bg hue+sat, fg lum
        r = setLum(bg, lum(fg));
        break;
    }

    return r;
}

// ── Blend pass ────────────────────────────────────────────────────────────────
// Composites scene and feedback according to FeedbackUniforms, then mixes the
// result against the raw scene by `decay`:
//   decay=0 → pure scene   |   decay=1 → full blend result

fragment float4 feedback_blend_fragment(
    FbQuadOut              in          [[stage_in]],
    texture2d<float>       sceneTex    [[texture(0)]],
    texture2d<float>       feedbackTex [[texture(1)]],
    constant FeedbackUniforms& u       [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 scene    = sceneTex.sample(s, in.uv);
    float4 feedback = feedbackTex.sample(s, in.uv);

    // scene.a is the content mask written by the render pass:
    //   alpha=1  geometry pixel  — chosen blend mode applies
    //   alpha=0  background pixel — feedback trail shows and decays, but the
    //            blend mode is NOT applied against the background colour so
    //            darkening modes don't kill the trail.
    float contentMask = scene.a;

    // ── Environment excluded from feedback ────────────────────────────────────
    // The scene texture holds the foreground ONLY (no skybox); empties are
    // transparent black.  Output premultiplied colour + a coverage alpha so the
    // caller can composite this over a freshly-drawn skybox.  Geometry is opaque;
    // trails over empty space fade toward transparent (both colour and coverage),
    // revealing the crisp background underneath as they age.
    if (u.excludeBackground != 0u) {
        float3 fg = (u.swapLayers != 0) ? feedback.rgb : scene.rgb;
        float3 bg = (u.swapLayers != 0) ? scene.rgb    : feedback.rgb;
        float3 geoRGB  = mix(scene.rgb, applyBlend(fg, bg, u.blendMode), u.decay);
        float3 trailRGB = feedback.rgb * u.decay;     // scene is transparent black here
        float  trailA   = feedback.a   * u.decay;
        float3 rgb = mix(trailRGB, geoRGB, contentMask);
        float  a   = mix(trailA,   1.0,    contentMask);
        return float4(rgb, a);
    }

    // ── Geometry pixels: apply the chosen blend mode ──────────────────────────
    float3 fg = (u.swapLayers != 0) ? feedback.rgb : scene.rgb;
    float3 bg = (u.swapLayers != 0) ? scene.rgb    : feedback.rgb;
    float3 blended        = applyBlend(fg, bg, u.blendMode);
    float3 geometryResult = mix(scene.rgb, blended, u.decay);

    // ── Background pixels: decay the feedback trail toward the background ──────
    // scene.rgb for a background pixel IS the background colour (clear colour or
    // gradient value), so mix(scene.rgb, feedback.rgb, decay) fades the trail
    // back toward the background at exactly the rate the user chose.
    float3 backgroundResult = mix(scene.rgb, feedback.rgb, u.decay);

    // Gate by content mask — smooth interpolation handles antialiased edges.
    float3 result = mix(backgroundResult, geometryResult, contentMask);

    return float4(result, 1.0);
}

// ── Blit pass ─────────────────────────────────────────────────────────────────

fragment float4 feedback_blit_fragment(
    FbQuadOut        in  [[stage_in]],
    texture2d<float> tex [[texture(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return tex.sample(s, in.uv);
}
