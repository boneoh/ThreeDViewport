import Foundation
import Combine
import simd

/// The kind of scene item a mark was captured from.  Drives the default colour and
/// the Timeline "Position Marks" grouping (one row per owning item).
enum MarkCategory: Int, Codable, CaseIterable {
    case object = 0
    case camera = 1
    case light  = 2
    case effect = 3

    var displayName: String {
        switch self {
        case .object: return "Object"
        case .camera: return "Camera"
        case .light:  return "Light"
        case .effect: return "Effect"
        }
    }

    /// Default mark colour by category: Object=Green, Camera=Red, Light=Yellow, Effect=Blue.
    var defaultColor: SIMD3<Float> {
        switch self {
        case .object: return SIMD3<Float>(0, 1, 0)
        case .camera: return SIMD3<Float>(1, 0, 0)
        case .light:  return SIMD3<Float>(1, 1, 0)
        case .effect: return SIMD3<Float>(0, 0, 1)
        }
    }
}

/// Identifies the scene item a mark belongs to (for default naming + the Timeline
/// "Position Marks" rows).  Index resolves cameras/lights/effects; objects also carry
/// name + occurrence so they survive reorder (mirrors the spin/orbit schedule keys).
struct MarkOwner: Equatable {
    var category:   MarkCategory
    var index:      Int            // camera / light / emitter slot, or object index at capture
    var name:       String         // owning item's display name (default mark name + resilience)
    var occurrence: Int = 0        // for objects: occurrence among same-named (0 otherwise)
}

/// A saved, named world-space position (a "mark") set from the Probe or an item's
/// Add Mark button.  Rendered as a smaller, single-colour version of the probe
/// gizmo; used as a positional reference for animating cameras / lights / objects.
struct ProbeMark: Identifiable {
    let id = UUID()
    var name:     String
    var position: SIMD3<Float>
    var color:    SIMD3<Float>      // colour (defaults by category; groups related marks)
    /// Scrub time captured when the mark was made (seconds).  Drives the Timeline row.
    var time:     Double = 0
    /// The item this mark was captured from (nil = legacy / probe-only mark).
    var owner:    MarkOwner? = nil
    /// Optional second point — a camera mark's aim/target (eye is `position`).
    var secondaryPosition: SIMD3<Float>? = nil
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
    /// Edit lock — freezes the probe panel's controls and viewport probe moves.
    @Published var isLocked: Bool = false

    init() {}
}
