#include <metal_stdlib>
using namespace metal;

// ── Shared vertex output ──────────────────────────────────────────────────────

struct FbQuadOut {
    float4 position [[position]];
    float2 uv;
};

// Generates a full-screen triangle strip from four procedural vertices.
// No vertex buffers needed — positions and UVs are computed from vertex_id.
vertex FbQuadOut feedback_vertex(uint vid [[vertex_id]]) {
    // NDC positions covering the full clip cube.
    constexpr float2 pos[4] = {
        float2(-1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0, -1.0),
        float2( 1.0,  1.0)
    };
    // Metal UV convention: (0,0) = top-left, (1,1) = bottom-right.
    constexpr float2 uvs[4] = {
        float2(0.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 1.0),
        float2(1.0, 0.0)
    };
    FbQuadOut out;
    out.position = float4(pos[vid], 0.0, 1.0);
    out.uv       = uvs[vid];
    return out;
}

// ── Blend pass ────────────────────────────────────────────────────────────────
// Linearly mixes the current scene frame with the feedback tap from the queue.
//   decay = 0.0  →  pure scene  (feedback has no effect)
//   decay = 1.0  →  pure feedback  (scene is invisible)
//   decay ≈ 0.5  →  equal blend  (typical artistic range)

fragment float4 feedback_blend_fragment(
    FbQuadOut        in          [[stage_in]],
    texture2d<float> sceneTex    [[texture(0)]],
    texture2d<float> feedbackTex [[texture(1)]],
    constant float&  decay       [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 scene    = sceneTex.sample(s, in.uv);
    float4 feedback = feedbackTex.sample(s, in.uv);
    return mix(scene, feedback, decay);
}

// ── Blit pass ─────────────────────────────────────────────────────────────────
// Pass-through: copies one texture to the current render target.
// Used to move the final result (scene or blend output) to the drawable.

fragment float4 feedback_blit_fragment(
    FbQuadOut        in  [[stage_in]],
    texture2d<float> tex [[texture(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return tex.sample(s, in.uv);
}
