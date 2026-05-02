import Combine

// Phase 8: Observable rendering settings shared between ViewportView,
// the inspector panel, and the menu bar.
// ViewportView subscribes via Combine and syncs isColorMode → Renderer.isColorMode
// so the renderer picks up the change on the next draw call.
final class RenderSettings: ObservableObject {

    // true  = full PBR color (default — most users expect colour)
    // false = greyscale (toggle with T or View > Color Rendering)
    @Published var isColorMode: Bool = true

    init() {
        print("[DEBUG] RenderSettings: initialized — color mode")
    }
}
