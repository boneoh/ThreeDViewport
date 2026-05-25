import Combine

/// The three render modes, in G-key cycle order.  Raw value is passed to the
/// shader's `colorMode` uniform (0 = greyscale, 1 = color, 2 = black + white).
enum RenderColorMode: Int, CaseIterable {
    case greyscale  = 0
    case color      = 1
    case blackWhite = 2

    var displayName: String {
        switch self {
        case .greyscale:  return "Greyscale"
        case .color:      return "Color"
        case .blackWhite: return "Black + White"
        }
    }

    /// Next mode for the G key: Greyscale → Color → Black+White → Greyscale.
    var next: RenderColorMode {
        switch self {
        case .greyscale:  return .color
        case .color:      return .blackWhite
        case .blackWhite: return .greyscale
        }
    }
}

// Phase 8: Observable rendering settings shared between ViewportView,
// the inspector panel, and the menu bar.
// ViewportView subscribes via Combine and syncs colorMode → Renderer.colorMode
// so the renderer picks up the change on the next draw call.
final class RenderSettings: ObservableObject {

    // Render mode: greyscale / full PBR color / black + white matte.
    // Cycle with G, or pick in Lights & Background → Rendering.
    @Published var colorMode: RenderColorMode = .color

    // When true, a small XYZ orientation gizmo is rendered in the bottom-right
    // corner of the viewport (and included in video exports).
    @Published var showAxesGizmo: Bool = false

    // Phase C: image-based-lighting intensity, 0 = off, 1 = full.
    // Written through to Renderer.ibl?.intensity by ViewportView's Combine sink.
    @Published var iblIntensity: Float = 1.0

    // Per-project Lighting HDR file path (drives the IBL).  Empty = bundled HDR.
    // The actual IBL reload is triggered on load / via File ▸ Open Lighting HDR.
    @Published var lightingHDRPath: String = ""

    init() {
        print("[DEBUG] RenderSettings: initialized — color mode")
    }
}
