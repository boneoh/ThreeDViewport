import Foundation
import Combine
import simd

/// A saved, named world-space position (a "mark") set from the Probe.  Rendered
/// as a smaller, single-colour version of the probe gizmo; used as a positional
/// reference for animating cameras / lights / objects.
struct ProbeMark: Identifiable {
    let id = UUID()
    var name:     String
    var position: SIMD3<Float>
    var color:    SIMD3<Float>      // user-chosen RGB (group related marks by colour)
}

/// Editor-only bake probe: the world-space point the scene is captured from when
/// baking an environment `.hdr`.  Drawn as an axis-cross gizmo in the live
/// viewport only (never exported), and positioned via the Probe inspector.
/// Also holds the project's saved position **marks**.
final class ProbeConfig: ObservableObject {
    /// World-space probe position (the capture origin).
    @Published var position:  SIMD3<Float> = .zero
    /// Whether the probe's gizmo is drawn in the viewport.
    @Published var isVisible: Bool         = false

    /// Saved named position marks (persisted with the project).
    @Published var marks: [ProbeMark] = []
    /// Whether all marks are drawn — in the viewport AND in exports.
    @Published var marksVisible: Bool = false
    /// Index into `marks` of the currently cycled/highlighted mark, if any.
    @Published var selectedMarkIndex: Int? = nil

    init() {}
}
