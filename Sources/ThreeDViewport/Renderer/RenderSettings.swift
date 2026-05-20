import Combine

// Phase 8: Observable rendering settings shared between ViewportView,
// the inspector panel, and the menu bar.
// ViewportView subscribes via Combine and syncs isColorMode → Renderer.isColorMode
// so the renderer picks up the change on the next draw call.
final class RenderSettings: ObservableObject {

    // true  = full PBR color (default — most users expect colour)
    // false = greyscale (toggle with T or View > Color Rendering)
    @Published var isColorMode: Bool = true

    // When true, a small XYZ orientation gizmo is rendered in the bottom-right
    // corner of the viewport (and included in video exports).
    @Published var showAxesGizmo: Bool = false

    // Phase C: image-based-lighting intensity, 0 = off, 1 = full.
    // Written through to Renderer.ibl?.intensity by ViewportView's Combine sink.
    @Published var iblIntensity: Float = 1.0

    init() {
        print("[DEBUG] RenderSettings: initialized — color mode")
    }
}
