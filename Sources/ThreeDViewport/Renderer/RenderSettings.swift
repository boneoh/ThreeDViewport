import Combine

// Phase 8: Observable rendering settings shared between ViewportView,
// the inspector panel, and the menu bar.
// ViewportView subscribes via Combine and syncs isColorMode → Renderer.isColorMode
// so the renderer picks up the change on the next draw call.
final class RenderSettings: ObservableObject {

    // false = greyscale (default — matches the video-synth workflow)
    // true  = full PBR color
    @Published var isColorMode: Bool = false

    init() {
        print("[DEBUG] RenderSettings: initialized — greyscale mode")
    }
}
