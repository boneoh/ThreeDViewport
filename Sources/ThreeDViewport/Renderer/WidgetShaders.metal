#include <metal_stdlib>
using namespace metal;

// ── Scene-mode widget shader ──────────────────────────────────────────────────
//
// Used by the Director's-POV view to draw wireframe gizmos for things that
// don't have meshes — the recording camera's frustum (Phase 2) and per-light
// gizmos (Phase 3).
//
// Vertices are world-space positions in a flat float3 buffer (buffer 0);
// uniforms supply the view-projection matrix and a single solid color.  No
// per-vertex color — color is uniform per draw call, which is fine because
// every widget is drawn as its own pass with its own color.
//
// Drawn with MTLPrimitiveType.line.  Depth test on, depth write off so widgets
// don't occlude each other but do get occluded by scene geometry behind them.

struct WidgetUniforms {
    float4x4 viewProjectionMatrix;  // 64 bytes
    float4   color;                 // 16  linear RGBA, unpremultiplied
};  // total: 80 bytes — keep in sync with Swift `WidgetUniforms`.

struct WidgetVOut {
    float4 position [[position]];
    float4 color;
};

// ── Vertex shader ─────────────────────────────────────────────────────────────

vertex WidgetVOut widget_vertex(
    constant float3         *vertices [[buffer(0)]],
    constant WidgetUniforms &u        [[buffer(1)]],
    uint                     vid      [[vertex_id]]
) {
    WidgetVOut out;
    out.position = u.viewProjectionMatrix * float4(vertices[vid], 1.0f);
    out.color    = u.color;
    return out;
}

// ── Fragment shader ───────────────────────────────────────────────────────────

fragment float4 widget_fragment(WidgetVOut in [[stage_in]]) {
    return in.color;
}
