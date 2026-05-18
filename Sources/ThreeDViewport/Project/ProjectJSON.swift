import Foundation

// Phase 4/5/6/8/9/10/11/12/14: Codable structs that define the .3dvp project file format (JSON).
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
//   8 — Added background (mode, solid colour, gradient colours) and isWireframe.
//   9 — Added blendMode and swapLayers to FeedbackData.
//  10 — Added lightConfigs array (per-light static config incl. beamThickness, excludeBeamFromFeedback).
//  11 — Added easingMode (Int) per ObjectData for per-track keyframe interpolation style.
//  12 — Added colorGrade (brightness Float, contrast Float).
//  13 — Added gamma to ColorGradeData.
//  14 — Phase 2 Timeline Hierarchy: added groupKeyframeTracks (group-level animation).
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
    var version:             Int     = 14
    var modelPath:           String? = nil   // v1/v2 compat; ignored when modelPaths non-empty.
    var modelPaths:          [String] = []   // v3 — ordered list of absolute .glb paths.
    var timeline:            TimelineData
    var camera:              CameraData
    var objects:             [ObjectData]
    var cameraKeyframes:     [CameraKeyframeData] = []  // v2; empty = no camera animation.
    var isColorMode:         Bool = true                // v4; color / greyscale toggle.
    var feedback:            FeedbackData = FeedbackData()  // v5; feedback delay-line settings.
    /// v6: one inner array per light slot (index 0–3).
    var lightKeyframeTracks: [[LightKeyframeData]] = []
    var isLooping:           Bool = false               // v7; false = stop at end.
    var background:          BackgroundData = BackgroundData()  // v8; background colour/gradient.
    var isWireframe:         Bool = false               // v8; wireframe rendering toggle.
    var showAxesGizmo:       Bool = false               // v8; XYZ orientation gizmo.
    var lightConfigs:        [LightConfigData] = []    // v10; per-light static config.
    var windowLayout:        WindowLayoutData  = WindowLayoutData()  // v11; panel positions.
    var colorGrade:          ColorGradeData   = ColorGradeData()    // v12; B/C post-process.
    /// v14 (Phase 2): group-level animation tracks, one per loaded multi-part model.
    var groupKeyframeTracks: [GroupTrackData] = []

    // MARK: - Memberwise init (required because we define init(from:) below)

    init(version:             Int                    = 14,
         modelPath:           String?                = nil,
         modelPaths:          [String]               = [],
         timeline:            TimelineData,
         camera:              CameraData,
         objects:             [ObjectData],
         cameraKeyframes:     [CameraKeyframeData]   = [],
         isColorMode:         Bool                   = true,
         feedback:            FeedbackData           = FeedbackData(),
         lightKeyframeTracks: [[LightKeyframeData]]  = [],
         isLooping:           Bool                   = false,
         background:          BackgroundData         = BackgroundData(),
         isWireframe:         Bool                   = false,
         showAxesGizmo:       Bool                   = false,
         lightConfigs:        [LightConfigData]      = [],
         windowLayout:        WindowLayoutData       = WindowLayoutData(),
         colorGrade:          ColorGradeData         = ColorGradeData(),
         groupKeyframeTracks: [GroupTrackData]       = []) {
        self.version             = version
        self.modelPath           = modelPath
        self.modelPaths          = modelPaths
        self.timeline            = timeline
        self.camera              = camera
        self.objects             = objects
        self.cameraKeyframes     = cameraKeyframes
        self.isColorMode         = isColorMode
        self.feedback            = feedback
        self.lightKeyframeTracks = lightKeyframeTracks
        self.isLooping           = isLooping
        self.background          = background
        self.isWireframe         = isWireframe
        self.showAxesGizmo       = showAxesGizmo
        self.lightConfigs        = lightConfigs
        self.windowLayout        = windowLayout
        self.colorGrade          = colorGrade
        self.groupKeyframeTracks = groupKeyframeTracks
    }

    // MARK: - Custom decoder
    //
    // Swift's synthesized Codable throws DecodingError.keyNotFound for ANY missing key,
    // even when the property has a default value.  We use try? so that project files saved
    // by older app versions load cleanly — missing keys fall back to the field defaults above.

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Required fields — present in every version
        timeline = try c.decode(TimelineData.self,  forKey: .timeline)
        camera   = try c.decode(CameraData.self,    forKey: .camera)
        objects  = try c.decode([ObjectData].self,  forKey: .objects)
        // Version-gated fields — absent in older files; fall back to defaults on failure
        version             = (try? c.decode(Int.self,                   forKey: .version))             ?? 1
        modelPath           =  try? c.decode(String.self,                forKey: .modelPath)
        modelPaths          = (try? c.decode([String].self,              forKey: .modelPaths))          ?? []
        cameraKeyframes     = (try? c.decode([CameraKeyframeData].self,  forKey: .cameraKeyframes))     ?? []
        isColorMode         = (try? c.decode(Bool.self,                  forKey: .isColorMode))         ?? true
        feedback            = (try? c.decode(FeedbackData.self,          forKey: .feedback))            ?? FeedbackData()
        lightKeyframeTracks = (try? c.decode([[LightKeyframeData]].self, forKey: .lightKeyframeTracks)) ?? []
        isLooping           = (try? c.decode(Bool.self,                  forKey: .isLooping))           ?? false
        background          = (try? c.decode(BackgroundData.self,        forKey: .background))          ?? BackgroundData()
        isWireframe         = (try? c.decode(Bool.self,                  forKey: .isWireframe))         ?? false
        showAxesGizmo       = (try? c.decode(Bool.self,                  forKey: .showAxesGizmo))       ?? false
        lightConfigs        = (try? c.decode([LightConfigData].self,     forKey: .lightConfigs))        ?? []
        windowLayout        = (try? c.decode(WindowLayoutData.self,      forKey: .windowLayout))        ?? WindowLayoutData()
        colorGrade          = (try? c.decode(ColorGradeData.self,        forKey: .colorGrade))          ?? ColorGradeData()
        groupKeyframeTracks = (try? c.decode([GroupTrackData].self,      forKey: .groupKeyframeTracks)) ?? []
    }
}

// v12: Brightness / contrast post-process.
// v13: Added gamma (Float, identity = 1.0).
// Defaults are identity so older project files load with no color grading applied.
struct ColorGradeData: Codable {
    var brightness: Float = 0.0   // identity = 0
    var contrast:   Float = 1.0   // identity = 1
    var gamma:      Float = 1.0   // identity = 1; v13 — absent in v12 files, falls back to 1.0

    // Custom decoder so v12 files (missing gamma) decode cleanly using the default.
    init(from decoder: Decoder) throws {
        let c  = try decoder.container(keyedBy: CodingKeys.self)
        brightness = (try? c.decode(Float.self, forKey: .brightness)) ?? 0.0
        contrast   = (try? c.decode(Float.self, forKey: .contrast))   ?? 1.0
        gamma      = (try? c.decode(Float.self, forKey: .gamma))      ?? 1.0
    }

    init(brightness: Float = 0.0, contrast: Float = 1.0, gamma: Float = 1.0) {
        self.brightness = brightness
        self.contrast   = contrast
        self.gamma      = gamma
    }
}

// v8: Background colour/gradient settings.  Defaults match BackgroundConfig initial values
// (solid black) so v1–v7 project files load with the standard black background.
struct BackgroundData: Codable {
    var mode:            Int   = 0      // BackgroundMode raw value: 0=solid, 1=gradient
    // Solid colour (RGB, linear 0–1)
    var solidR:          Float = 0
    var solidG:          Float = 0
    var solidB:          Float = 0
    // Gradient top colour
    var gradTopR:        Float = 0.05
    var gradTopG:        Float = 0.06
    var gradTopB:        Float = 0.14
    // Gradient bottom colour
    var gradBottomR:     Float = 0
    var gradBottomG:     Float = 0
    var gradBottomB:     Float = 0
}

// v5: Feedback delay-line settings.  Defaults match FeedbackSettings initial values
// so v1–v4 project files load with feedback disabled.
// v9: added blendMode (Int raw value) and swapLayers (Bool).
struct FeedbackData: Codable {
    var isEnabled:  Bool  = false
    var interval:   Int   = 10
    var decay:      Float = 0.5
    var length:     Int   = 10
    var blendMode:  Int   = 0       // BlendMode.normal
    var swapLayers: Bool  = false

    // Custom decoder so files saved before v9 (missing blendMode/swapLayers)
    // load cleanly using the defaults above.
    init(from decoder: Decoder) throws {
        let c        = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled    = (try? c.decode(Bool.self,  forKey: .isEnabled))  ?? false
        interval     = (try? c.decode(Int.self,   forKey: .interval))   ?? 10
        decay        = (try? c.decode(Float.self, forKey: .decay))      ?? 0.5
        length       = (try? c.decode(Int.self,   forKey: .length))     ?? 10
        blendMode    = (try? c.decode(Int.self,   forKey: .blendMode))  ?? 0
        swapLayers   = (try? c.decode(Bool.self,  forKey: .swapLayers)) ?? false
    }

    init(isEnabled:  Bool  = false,
         interval:   Int   = 10,
         decay:      Float = 0.5,
         length:     Int   = 10,
         blendMode:  Int   = 0,
         swapLayers: Bool  = false) {
        self.isEnabled  = isEnabled
        self.interval   = interval
        self.decay      = decay
        self.length     = length
        self.blendMode  = blendMode
        self.swapLayers = swapLayers
    }
}

// v11: Position and size of one window or floating panel.
struct WindowFrameData: Codable {
    var x: Double = 0
    var y: Double = 0
    var w: Double = 1920
    var h: Double = 1160
}

// v11: Saved layout for all managed windows.
// nil panel entries = that panel was closed; don't reopen on load.
struct WindowLayoutData: Codable {
    var mainWindow:     WindowFrameData  = WindowFrameData()  // always saved
    var timelineEditor: WindowFrameData? = nil                // nil = was closed
    var lightsPanel:    WindowFrameData? = nil
    var feedbackPanel:  WindowFrameData? = nil
    var colorGradePanel: WindowFrameData? = nil
    var cameraPanel:    WindowFrameData? = nil
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
    /// Vertical FOV in radians at save time. Absent in project files saved before
    /// the focal-length-persistence change; loader backfills with the codebase
    /// default (27°) so older projects play back at a known FOV.
    var fov:      Float? = nil

    // Custom decoder so files without `fov` (pre-FOV-persistence) decode cleanly.
    init(from decoder: Decoder) throws {
        let c    = try decoder.container(keyedBy: CodingKeys.self)
        yaw      = try  c.decode(Float.self, forKey: .yaw)
        pitch    = try  c.decode(Float.self, forKey: .pitch)
        distance = try  c.decode(Float.self, forKey: .distance)
        targetX  = try  c.decode(Float.self, forKey: .targetX)
        targetY  = try  c.decode(Float.self, forKey: .targetY)
        targetZ  = try  c.decode(Float.self, forKey: .targetZ)
        fov      = try? c.decode(Float.self, forKey: .fov)
    }

    init(yaw: Float, pitch: Float, distance: Float,
         targetX: Float, targetY: Float, targetZ: Float,
         fov: Float? = nil) {
        self.yaw      = yaw
        self.pitch    = pitch
        self.distance = distance
        self.targetX  = targetX
        self.targetY  = targetY
        self.targetZ  = targetZ
        self.fov      = fov
    }
}

struct ObjectData: Codable {
    var name:      String
    var keyframes: [KeyframeData]
    // v4: column-major 4×4 matrix (16 floats).  Empty array = use GLB default (v1–v3 compat).
    var baseTransformMatrix: [Float] = []
    // v11: EasingMode.rawValue.  0 = .linear (default) — missing key in older files
    //      is decoded as 0 so pre-v11 projects load with unchanged linear behaviour.
    var easingMode: Int = 0

    // Custom decoder so files without baseTransformMatrix (v1–v3) or easingMode (v1–v10)
    // decode cleanly using the defaults above instead of throwing keyNotFound.
    init(from decoder: Decoder) throws {
        let c                = try decoder.container(keyedBy: CodingKeys.self)
        name                 = try  c.decode(String.self,        forKey: .name)
        keyframes            = try  c.decode([KeyframeData].self, forKey: .keyframes)
        baseTransformMatrix  = (try? c.decode([Float].self,       forKey: .baseTransformMatrix)) ?? []
        easingMode           = (try? c.decode(Int.self,           forKey: .easingMode))          ?? 0
    }

    init(name: String, keyframes: [KeyframeData],
         baseTransformMatrix: [Float] = [], easingMode: Int = 0) {
        self.name                = name
        self.keyframes           = keyframes
        self.baseTransformMatrix = baseTransformMatrix
        self.easingMode          = easingMode
    }
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
// Camera Follow (Phase N): added followTarget — nil = free camera, non-nil = follow named object.
struct CameraKeyframeData: Codable {
    var time:         Double
    var yaw:          Float
    var pitch:        Float
    var distance:     Float
    var targetX:      Float
    var targetY:      Float
    var targetZ:      Float
    /// Vertical FOV (focal length) at this keyframe, in radians.
    /// Absent in older project files — loader backfills with the static
    /// CameraData.fov (or the codebase default, 27°).
    var fov:          Float? = nil
    /// nil = free camera (default, absent in older project files).
    var followTarget:    String? = nil
    /// Camera yaw stored as an offset from the object's "behind yaw" at creation time.
    /// nil = no yaw-relative follow (absolute yaw / position-only follow).
    var followYawOffset: Float?  = nil
    /// Camera pitch stored as an offset from the object's "behind pitch" at
    /// creation time.  Lets the camera tilt with the followed object when
    /// the object pitches up/down.  nil = no pitch-relative follow (camera
    /// pitch from keyframe, absolute).  Absent in older project files saved
    /// before pitch-follow was added.
    var followPitchOffset: Float? = nil
    /// World-space offset from the node origin to the camera target at creation time.
    /// nil / absent in older project files — treated as (0, 0, 0) on load.
    var targetOffset: [Float]? = nil

    // Custom decoder so files saved before camera-follow / FOV / pitch-follow fields decode cleanly.
    init(from decoder: Decoder) throws {
        let c    = try decoder.container(keyedBy: CodingKeys.self)
        time     = try  c.decode(Double.self, forKey: .time)
        yaw      = try  c.decode(Float.self,  forKey: .yaw)
        pitch    = try  c.decode(Float.self,  forKey: .pitch)
        distance = try  c.decode(Float.self,  forKey: .distance)
        targetX  = try  c.decode(Float.self,  forKey: .targetX)
        targetY  = try  c.decode(Float.self,  forKey: .targetY)
        targetZ  = try  c.decode(Float.self,  forKey: .targetZ)
        fov               = try? c.decode(Float.self,   forKey: .fov)
        followTarget      = try? c.decode(String.self,  forKey: .followTarget)
        followYawOffset   = try? c.decode(Float.self,   forKey: .followYawOffset)
        followPitchOffset = try? c.decode(Float.self,   forKey: .followPitchOffset)
        targetOffset      = try? c.decode([Float].self, forKey: .targetOffset)
    }

    init(time: Double, yaw: Float, pitch: Float, distance: Float,
         targetX: Float, targetY: Float, targetZ: Float,
         fov: Float? = nil,
         followTarget: String? = nil,
         followYawOffset: Float? = nil,
         followPitchOffset: Float? = nil,
         targetOffset: [Float]? = nil) {
        self.time              = time
        self.yaw               = yaw
        self.pitch             = pitch
        self.distance          = distance
        self.targetX           = targetX
        self.targetY           = targetY
        self.targetZ           = targetZ
        self.fov               = fov
        self.followTarget      = followTarget
        self.followYawOffset   = followYawOffset
        self.followPitchOffset = followPitchOffset
        self.targetOffset      = targetOffset
    }
}

// v10: Static per-light configuration.  All fields have sensible defaults so
// files saved before v10 (missing lightConfigs key) reload cleanly.
struct LightConfigData: Codable {
    var type:                    Int   = 1      // LightType.rawValue  (1 = directional)
    var isEnabled:               Bool  = true
    var colorR:                  Float = 1.0
    var colorG:                  Float = 1.0
    var colorB:                  Float = 1.0
    var intensity:               Float = 1.0
    var posX:                    Float = 0.0
    var posY:                    Float = 3.0
    var posZ:                    Float = 3.0
    var dirX:                    Float = 0.5
    var dirY:                    Float = -1.2
    var dirZ:                    Float = -0.8
    var innerConeAngle:          Float = 0.3927  // π/8
    var outerConeAngle:          Float = 0.5236  // π/6
    var range:                   Float = 15.0
    var beamThickness:           Float = 1.0
    var excludeBeamFromFeedback: Bool  = false
}

// v6: One saved light keyframe — intensity, colour, direction, position.
// v11: Added range and beamThickness.
// Type, cone angles, and enabled state are not animated; restore them from LightConfig.
struct LightKeyframeData: Codable {
    var time:          Double
    var intensity:     Float
    // Colour components
    var r: Float; var g: Float; var b: Float
    // Direction (normalised)
    var dx: Float; var dy: Float; var dz: Float
    // Position
    var px: Float; var py: Float; var pz: Float
    // v11: beam properties (default to LightConfig defaults for older project files)
    var range:         Float = 15.0
    var beamThickness: Float = 1.0
}

// v14 (Phase 2 Timeline Hierarchy): Group-level animation track.
// Keyed by sourceFileName (the last path component of the model URL) so that
// group IDs — which are runtime ephemeral — can be reconnected on load.
// The keyframe payload reuses KeyframeData (TRS delta, quaternion rotation).
struct GroupTrackData: Codable {
    /// The filename (e.g. "robot.glb") of the model whose group this track animates.
    var sourceFileName: String
    /// EasingMode.rawValue — 0 = .linear.  Absent in older files → 0.
    var easingMode:     Int = 0
    /// The keyframe array for this group track.
    var keyframes:      [KeyframeData] = []
}
