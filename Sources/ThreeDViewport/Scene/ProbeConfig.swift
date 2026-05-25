import Combine
import simd

/// Editor-only bake probe: the world-space point the scene is captured from when
/// baking an environment `.hdr`.  Drawn as an axis-cross gizmo in the live
/// viewport only (never exported), and positioned via the Probe inspector.
final class ProbeConfig: ObservableObject {
    /// World-space probe position (the capture origin).
    @Published var position:  SIMD3<Float> = .zero
    /// Whether the probe's gizmo is drawn in the viewport.
    @Published var isVisible: Bool         = false

    init() {}
}
