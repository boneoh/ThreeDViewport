import Foundation

// Phase 4/5/6/8/9/10/11: Codable structs that define the .3dvp project file format (JSON).
// Version history:
//   1 — initial: model path, camera, timeline, per-object keyframe tracks.
//   2 — Phase 5: added cameraKeyframes array.
//   3 — Phase 6: replaced single modelPath with modelPaths array for multi-object scenes.
//               modelPath kept as optional for v1/v2 backward compatibility.
//   4 — Phase 8: added isColorMode; added baseTransformMatrix per object so manually
//               repositioned objects are restored correctly without requiring a keyframe.
//   5 — Phase 9: added feedback settings (isEnabled, interval, decay, length).
//   6 — Phase 10: added lightKeyframeTracks — one array of keyframes per light slot (0–3).
//   7 — Phase 11: added isLooping (loop playback toggle).
//
// Design rules:
//   • No binary data inline — .glb files are referenced by absolute path.
//   • Object keyframes store TRS *deltas* relative to baseTransform, matching the
//     renderer convention:  object.transform = baseTransform * animDelta.
//   • Camera keyframes are ABSOLUTE — evaluated state is written directly to
//     CameraController (yaw / pitch / distance / target).
//   • Forward compatibility: unknown keys are silently ignored by JSONDecoder.
//     All new fields have defaults so older files load without error.

struct ProjectData: Codable {
    var version:             Int     = 7
    var modelPath:           String? = nil   // v1/v2 compat; ignored when modelPaths non-empty.
    var modelPaths:          [String] = []   // v3 — ordered list of absolute .glb paths.
    var timeline:            TimelineData
    var camera:              CameraData
    var objects:             [ObjectData]
    var cameraKeyframes:     [CameraKeyframeData] = []  // Phase 5; empty = no camera animation.
    // v4 additions (default values make old files load cleanly):
    var isColorMode:         Bool = true                // Phase 8 color / greyscale toggle.
    // v5 additions:
    var feedback:            FeedbackData = FeedbackData()  // feedback delay-line settings.
    // v6 additions:
    /// One inner array per light slot (index 0–3). Empty inner array = no animation for that slot.
    /// Outer array may be shorter than the light count if trailing slots have no keyframes.
    var lightKeyframeTracks: [[LightKeyframeData]] = []
    // v7 additions:
    var isLooping:           Bool = false               // loop playback toggle; false = stop at end.
}

// v5: Feedback delay-line settings.  Defaults match FeedbackSettings initial values
// so v1–v4 project files load with feedback disabled.
struct FeedbackData: Codable {
    var isEnabled: Bool  = false
    var interval:  Int   = 10
    var decay:     Float = 0.5
    var length:    Int   = 10
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

// v6: One saved light keyframe — intensity, colour, direction, position.
// Type, cone angles, and enabled state are not animated; restore them from LightConfig.
struct LightKeyframeData: Codable {
    var time:      Double
    var intensity: Float
    // Colour components
    var r: Float; var g: Float; var b: Float
    // Direction (normalised)
    var dx: Float; var dy: Float; var dz: Float
    // Position
    var px: Float; var py: Float; var pz: Float
}
