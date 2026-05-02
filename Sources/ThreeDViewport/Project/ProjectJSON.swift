import Foundation

// Phase 4/5/6/8: Codable structs that define the .3dvp project file format (JSON).
// Version history:
//   1 — initial: model path, camera, timeline, per-object keyframe tracks.
//   2 — Phase 5: added cameraKeyframes array.
//   3 — Phase 6: replaced single modelPath with modelPaths array for multi-object scenes.
//               modelPath kept as optional for v1/v2 backward compatibility.
//   4 — Phase 8: added isColorMode; added baseTransformMatrix per object so manually
//               repositioned objects are restored correctly without requiring a keyframe.
//
// Design rules:
//   • No binary data inline — .glb files are referenced by absolute path.
//   • Object keyframes store TRS *deltas* relative to baseTransform, matching the
//     renderer convention:  object.transform = baseTransform * animDelta.
//   • Camera keyframes are ABSOLUTE — evaluated state is written directly to
//     CameraController (yaw / pitch / distance / target).
//   • Forward compatibility: unknown keys are silently ignored by JSONDecoder.
//     All new v4 fields have defaults so v1–v3 files load without error.

struct ProjectData: Codable {
    var version:         Int     = 4
    var modelPath:       String? = nil  // v1/v2 compat — single model path; ignored when modelPaths non-empty.
    var modelPaths:      [String] = []  // v3 — ordered list of absolute .glb paths.
    var timeline:        TimelineData
    var camera:          CameraData
    var objects:         [ObjectData]
    var cameraKeyframes: [CameraKeyframeData] = []  // Phase 5; empty = no camera animation.
    // v4 additions (default values make old files load cleanly):
    var isColorMode:     Bool = true                // Phase 8 color / greyscale toggle.
}

struct TimelineData: Codable {
    var duration:    Double
    var currentTime: Double
}

struct CameraData: Codable {
    var yaw:      Float
    var pitch:    Float
    var distance: Float
    var targetX:  Float
    var targetY:  Float
    var targetZ:  Float
}

struct ObjectData: Codable {
    var name:      String
    var keyframes: [KeyframeData]
    // v4: column-major 4×4 matrix (16 floats).  Empty array = use GLB default (v1–v3 compat).
    var baseTransformMatrix: [Float] = []
}

// One saved object keyframe — full TRS of the animation delta.
// Quaternion stored as (rx=ix, ry=iy, rz=iz, rw=real) to match simd_quatf components.
struct KeyframeData: Codable {
    var time: Double
    // Translation
    var tx: Float; var ty: Float; var tz: Float
    // Rotation quaternion (ix, iy, iz, real)
    var rx: Float; var ry: Float; var rz: Float; var rw: Float
    // Scale
    var sx: Float; var sy: Float; var sz: Float
}

// Phase 5: One saved camera keyframe — absolute camera state.
// Yaw uses shortest-path interpolation in CameraKeyframeTrack.evaluate(at:).
struct CameraKeyframeData: Codable {
    var time:     Double
    var yaw:      Float
    var pitch:    Float
    var distance: Float
    var targetX:  Float
    var targetY:  Float
    var targetZ:  Float
}
