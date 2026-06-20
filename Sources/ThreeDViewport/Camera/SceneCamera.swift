import simd
import Foundation

/// A scheduled hard cut: from `time` onward (until the next cut) the program camera is
/// `cameraIndex` (an index into ViewportView.cameras).  Drives playback + export.
struct CameraCut: Identifiable {
    let id = UUID()
    var time: Double
    var cameraIndex: Int
}

/// One scene camera's authored state.  The ACTIVE camera is edited and rendered through
/// the live `CameraController`; every camera (active or not) keeps a copy of its state
/// here so the project can hold multiple cameras (Phase 1).  In Phase 1a there is exactly
/// one camera ("Camera 1") and behavior is identical to the single-camera app.
final class SceneCamera {
    // Stable identity (identity refactor P0).  Restored on load; a new camera gets a
    // fresh one.  Future canonical reference (replacing camera array index / cut index).
    var entityID = UUID()
    var name:          String
    var yaw:           Float
    var pitch:         Float
    var distance:      Float
    var target:        SIMD3<Float>
    var fovYRadians:   Float
    var keyframeTrack: CameraKeyframeTrack?
    var isLocked:      Bool

    init(name: String,
         yaw: Float = 0.0,
         pitch: Float = 0.4,
         distance: Float = 5.0,
         target: SIMD3<Float> = .zero,
         fovYRadians: Float = 27.0 * Float.pi / 180.0,
         keyframeTrack: CameraKeyframeTrack? = nil,
         isLocked: Bool = false) {
        self.name          = name
        self.yaw           = yaw
        self.pitch         = pitch
        self.distance      = distance
        self.target        = target
        self.fovYRadians   = fovYRadians
        self.keyframeTrack = keyframeTrack
        self.isLocked      = isLocked
    }
}
