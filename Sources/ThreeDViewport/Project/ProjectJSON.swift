import Foundation

// Phase 4/5/6/8/9/10/11/12/14/15: Codable structs that define the .3dvp project file format (JSON).
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
//  15 — Model Inspector: added isVisible, normalMode, metallicFactor, roughnessFactor,
//       baseColorFactor per ObjectData; added modelInspectorPanel to WindowLayoutData.
//  16 — IBL: added top-level iblIntensity, and exposure to ColorGradeData.
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
    var version:             Int     = 16
    var modelPath:           String? = nil   // v1/v2 compat; ignored when modelPaths non-empty.
    var modelPaths:          [String] = []   // v3 — ordered list of absolute .glb paths.
    var timeline:            TimelineData
    var camera:              CameraData
    var objects:             [ObjectData]
    var cameraKeyframes:     [CameraKeyframeData] = []  // v2; empty = no camera animation.
    var isColorMode:         Bool = true                // v4; legacy color/greyscale flag (kept for migration + old-app compat).
    var colorMode:           Int  = 1                   // v18; RenderColorMode raw (0=greyscale, 1=color, 2=black+white).
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
    var iblIntensity:        Float = 1.0                 // v16; per-scene IBL strength.
    var lightingHDRPath:     String = ""                 // v28; per-project Lighting HDR path (empty = bundled).
    var fog:                 FogData = FogData()         // v19/v22; fog volume (atmosphere).
    var particles:           ParticleEffectData = ParticleEffectData()  // v21; legacy single emitter (migration).
    var fogKeyframes:        [AtmosphereKeyframeData] = []  // v23; fog volume animation.
    var particleKeyframes:   [AtmosphereKeyframeData] = []  // v23; legacy single emitter track (migration).
    var particleEmitters:        [ParticleEffectData] = []        // v24; multiple particle emitters.
    var particleEmitterKeyframes: [[AtmosphereKeyframeData]] = [] // v24; per-emitter animation.
    var probe:                   ProbeData = ProbeData()          // v29; bake probe position.
    // v32: per-track easing (EasingMode.rawValue) for the non-object tracks.
    // Default 0 (.linear) so older project files animate exactly as before.
    var cameraEasingMode:        Int   = 0
    var lightEasingModes:        [Int] = []   // parallel to lightKeyframeTracks
    var fogEasingMode:           Int   = 0
    var particleEmitterEasingModes: [Int] = []   // parallel to particleEmitterKeyframes
    /// v31: per-group static gt snapshot.  Persists slider/Model-mode edits
    /// to groupTransforms[gid] that aren't recorded as keyframes (e.g. setting
    /// the station's scale once for the whole project).  Tracked groups still
    /// save an entry but the track evaluator overwrites it on first frame.
    var groupBaseTransforms:    [GroupBaseTransformData] = []
    /// v34: Glue envelopes — geometryless null nodes that parent member objects so
    /// they animate as a unit.  Empty for older files, which load unchanged.
    var envelopes:              [EnvelopeData] = []
    /// v35: rate-marker schedules for the Spin / Orbit animators (the editable source
    /// of truth behind the baked keyframes).  Empty for older files.
    var spinRateSchedules:      [SpinRateScheduleData]  = []
    var orbitRateSchedules:     [OrbitRateScheduleData] = []

    // MARK: - Memberwise init (required because we define init(from:) below)

    init(version:             Int                    = 16,
         modelPath:           String?                = nil,
         modelPaths:          [String]               = [],
         timeline:            TimelineData,
         camera:              CameraData,
         objects:             [ObjectData],
         cameraKeyframes:     [CameraKeyframeData]   = [],
         isColorMode:         Bool                   = true,
         colorMode:           Int                    = 1,
         feedback:            FeedbackData           = FeedbackData(),
         lightKeyframeTracks: [[LightKeyframeData]]  = [],
         isLooping:           Bool                   = false,
         background:          BackgroundData         = BackgroundData(),
         isWireframe:         Bool                   = false,
         showAxesGizmo:       Bool                   = false,
         lightConfigs:        [LightConfigData]      = [],
         windowLayout:        WindowLayoutData       = WindowLayoutData(),
         colorGrade:          ColorGradeData         = ColorGradeData(),
         groupKeyframeTracks: [GroupTrackData]       = [],
         iblIntensity:        Float                  = 1.0,
         lightingHDRPath:     String                 = "",
         fog:                 FogData                = FogData(),
         particles:           ParticleEffectData     = ParticleEffectData(),
         fogKeyframes:        [AtmosphereKeyframeData] = [],
         particleKeyframes:   [AtmosphereKeyframeData] = [],
         particleEmitters:    [ParticleEffectData]    = [],
         particleEmitterKeyframes: [[AtmosphereKeyframeData]] = [],
         probe:               ProbeData               = ProbeData(),
         groupBaseTransforms: [GroupBaseTransformData] = [],
         cameraEasingMode:    Int                     = 0,
         lightEasingModes:    [Int]                   = [],
         fogEasingMode:       Int                     = 0,
         particleEmitterEasingModes: [Int]            = [],
         envelopes:           [EnvelopeData]          = [],
         spinRateSchedules:   [SpinRateScheduleData]  = [],
         orbitRateSchedules:  [OrbitRateScheduleData] = []) {
        self.version             = version
        self.modelPath           = modelPath
        self.modelPaths          = modelPaths
        self.timeline            = timeline
        self.camera              = camera
        self.objects             = objects
        self.cameraKeyframes     = cameraKeyframes
        self.isColorMode         = isColorMode
        self.colorMode           = colorMode
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
        self.iblIntensity        = iblIntensity
        self.lightingHDRPath     = lightingHDRPath
        self.fog                 = fog
        self.particles           = particles
        self.fogKeyframes        = fogKeyframes
        self.particleKeyframes   = particleKeyframes
        self.particleEmitters    = particleEmitters
        self.particleEmitterKeyframes = particleEmitterKeyframes
        self.probe               = probe
        self.groupBaseTransforms = groupBaseTransforms
        self.cameraEasingMode    = cameraEasingMode
        self.lightEasingModes    = lightEasingModes
        self.fogEasingMode       = fogEasingMode
        self.particleEmitterEasingModes = particleEmitterEasingModes
        self.envelopes           = envelopes
        self.spinRateSchedules   = spinRateSchedules
        self.orbitRateSchedules  = orbitRateSchedules
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
        // v18: prefer the explicit 3-state colorMode; older files only have the
        // legacy isColorMode bool, so map true→color(1), false→greyscale(0).
        colorMode           = (try? c.decode(Int.self,                   forKey: .colorMode))           ?? (isColorMode ? 1 : 0)
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
        iblIntensity        = (try? c.decode(Float.self,                 forKey: .iblIntensity))        ?? 1.0
        lightingHDRPath     = (try? c.decode(String.self,                forKey: .lightingHDRPath))     ?? ""
        fog                 = (try? c.decode(FogData.self,               forKey: .fog))                 ?? FogData()
        particles           = (try? c.decode(ParticleEffectData.self,    forKey: .particles))           ?? ParticleEffectData()
        fogKeyframes        = (try? c.decode([AtmosphereKeyframeData].self, forKey: .fogKeyframes))      ?? []
        particleKeyframes   = (try? c.decode([AtmosphereKeyframeData].self, forKey: .particleKeyframes)) ?? []
        particleEmitters         = (try? c.decode([ParticleEffectData].self,        forKey: .particleEmitters))         ?? []
        particleEmitterKeyframes = (try? c.decode([[AtmosphereKeyframeData]].self,  forKey: .particleEmitterKeyframes)) ?? []
        probe               = (try? c.decode(ProbeData.self,             forKey: .probe))               ?? ProbeData()
        groupBaseTransforms = (try? c.decode([GroupBaseTransformData].self, forKey: .groupBaseTransforms)) ?? []
        cameraEasingMode    = (try? c.decode(Int.self,   forKey: .cameraEasingMode))    ?? 0
        lightEasingModes    = (try? c.decode([Int].self, forKey: .lightEasingModes))    ?? []
        fogEasingMode       = (try? c.decode(Int.self,   forKey: .fogEasingMode))       ?? 0
        particleEmitterEasingModes = (try? c.decode([Int].self, forKey: .particleEmitterEasingModes)) ?? []
        envelopes           = (try? c.decode([EnvelopeData].self, forKey: .envelopes)) ?? []
        spinRateSchedules   = (try? c.decode([SpinRateScheduleData].self,  forKey: .spinRateSchedules))  ?? []
        orbitRateSchedules  = (try? c.decode([OrbitRateScheduleData].self, forKey: .orbitRateSchedules)) ?? []
    }
}

// v35: rate-marker schedules for the Spin / Orbit animators.  Tracks are matched
// on load by identity: object by name, group by groupID, light by index, camera is
// the singleton.  The baked keyframes themselves persist in the regular tracks;
// these structs only preserve the editable rate markers.
struct SpinRateMarkerData: Codable {
    var time:      Double
    var rate:      Double
    var axisIndex: Int
}

struct SpinRateScheduleData: Codable {
    var targetKind:  Int    // 2 = object, 3 = group
    var targetName:  String // object name (kind 2)
    var targetIndex: Int    // groupID (kind 3)
    var markers:     [SpinRateMarkerData]
}

struct OrbitRateMarkerData: Codable {
    var time: Double
    var rate: Double
}

struct OrbitRateScheduleData: Codable {
    var targetKind:  Int      // 0 = camera, 1 = light, 2 = object
    var targetName:  String   // object name (kind 2)
    var targetIndex: Int      // light index (kind 1)
    var axisStart:   [Float]  // 3 floats
    var axisEnd:     [Float]  // 3 floats
    var radius:      Float
    var markers:     [OrbitRateMarkerData]
}

// v34: One Glue envelope.  `transform` is the column-major 4×4 origin matrix (16
// floats).  `memberIndices` reference objects by their position in the rebuilt
// object array — the same positional convention the loader already uses to
// reattach per-object state (isVisible, objectClass, …).  Members re-derive their
// localTransform from this origin on load, so nothing is stored per member.
struct EnvelopeData: Codable {
    var name:          String
    var transform:     [Float]        = []   // 16 floats, column-major
    var keyframes:     [KeyframeData] = []
    var easingMode:    Int            = 0
    var memberIndices: [Int]          = []

    init(from decoder: Decoder) throws {
        let c          = try decoder.container(keyedBy: CodingKeys.self)
        name           = (try? c.decode(String.self,        forKey: .name))          ?? "Envelope"
        transform      = (try? c.decode([Float].self,       forKey: .transform))     ?? []
        keyframes      = (try? c.decode([KeyframeData].self, forKey: .keyframes))     ?? []
        easingMode     = (try? c.decode(Int.self,           forKey: .easingMode))    ?? 0
        memberIndices  = (try? c.decode([Int].self,         forKey: .memberIndices)) ?? []
    }

    init(name: String, transform: [Float], keyframes: [KeyframeData],
         easingMode: Int, memberIndices: [Int]) {
        self.name          = name
        self.transform     = transform
        self.keyframes     = keyframes
        self.easingMode    = easingMode
        self.memberIndices = memberIndices
    }
}

// v29: bake probe world position.  v33+: saved position marks.
struct ProbeData: Codable {
    var px: Float = 0
    var py: Float = 0
    var pz: Float = 0
    /// Optional so projects saved before v33 (no `marks` key) still decode — a
    /// missing key becomes nil rather than throwing and resetting the probe.
    var marks:        [MarkData]? = nil
    var marksVisible: Bool?       = nil
}

// v33: one saved position mark (name + world position + RGB colour).
struct MarkData: Codable {
    var name: String = ""
    var px: Float = 0; var py: Float = 0; var pz: Float = 0
    var r:  Float = 1; var g:  Float = 1; var b:  Float = 1
}

// v23: One atmosphere keyframe (fog volume or particle emitter).  Mirrors
// AtmosphereKeyframe; whole-effect snapshot at `time`.
struct AtmosphereKeyframeData: Codable {
    var time: Double
    var px: Float; var py: Float; var pz: Float
    var sx: Float; var sy: Float; var sz: Float
    var density:  Float
    var variance: Float
    var r: Float; var g: Float; var b: Float
}

// v12: Brightness / contrast post-process.
// v13: Added gamma (Float, identity = 1.0).
// Defaults are identity so older project files load with no color grading applied.
struct ColorGradeData: Codable {
    var exposure:   Float = 1.0   // identity = 1; v16 — pre-tone-map scene exposure
    var brightness: Float = 0.0   // identity = 0
    var contrast:   Float = 1.0   // identity = 1
    var gamma:      Float = 1.0   // identity = 1; v13 — absent in v12 files, falls back to 1.0

    // Custom decoder so older files (missing exposure/gamma) decode cleanly using defaults.
    init(from decoder: Decoder) throws {
        let c  = try decoder.container(keyedBy: CodingKeys.self)
        exposure   = (try? c.decode(Float.self, forKey: .exposure))   ?? 1.0
        brightness = (try? c.decode(Float.self, forKey: .brightness)) ?? 0.0
        contrast   = (try? c.decode(Float.self, forKey: .contrast))   ?? 1.0
        gamma      = (try? c.decode(Float.self, forKey: .gamma))      ?? 1.0
    }

    init(exposure: Float = 1.0, brightness: Float = 0.0, contrast: Float = 1.0, gamma: Float = 1.0) {
        self.exposure   = exposure
        self.brightness = brightness
        self.contrast   = contrast
        self.gamma      = gamma
    }
}

// v19: distance fog.  v22: repurposed as the raymarched fog volume (box).
// Defaults match FogSettings (off, mid-grey, ground-hugging box) so older project
// files load with fog disabled; the legacy `start` key is simply ignored.
struct FogData: Codable {
    var isEnabled: Bool  = false
    var r: Float = 0.5
    var g: Float = 0.5
    var b: Float = 0.5
    var density: Float = 0.15
    var px: Float = 0;  var py: Float = 1; var pz: Float = 0
    var sx: Float = 12; var sy: Float = 4; var sz: Float = 12
    var variance: Float = 0.5
    var steps:    Float = 48          // v25; raymarch quality (steps per ray)

    init(from decoder: Decoder) throws {
        let c     = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = (try? c.decode(Bool.self,  forKey: .isEnabled)) ?? false
        r         = (try? c.decode(Float.self, forKey: .r))         ?? 0.5
        g         = (try? c.decode(Float.self, forKey: .g))         ?? 0.5
        b         = (try? c.decode(Float.self, forKey: .b))         ?? 0.5
        density   = (try? c.decode(Float.self, forKey: .density))   ?? 0.15
        px        = (try? c.decode(Float.self, forKey: .px))        ?? 0
        py        = (try? c.decode(Float.self, forKey: .py))        ?? 1
        pz        = (try? c.decode(Float.self, forKey: .pz))        ?? 0
        sx        = (try? c.decode(Float.self, forKey: .sx))        ?? 12
        sy        = (try? c.decode(Float.self, forKey: .sy))        ?? 4
        sz        = (try? c.decode(Float.self, forKey: .sz))        ?? 12
        variance  = (try? c.decode(Float.self, forKey: .variance))  ?? 0.5
        steps     = (try? c.decode(Float.self, forKey: .steps))     ?? 48
    }

    init(isEnabled: Bool = false, r: Float = 0.5, g: Float = 0.5, b: Float = 0.5,
         density: Float = 0.15,
         px: Float = 0, py: Float = 1, pz: Float = 0,
         sx: Float = 12, sy: Float = 4, sz: Float = 12,
         variance: Float = 0.5, steps: Float = 48) {
        self.isEnabled = isEnabled
        self.r = r; self.g = g; self.b = b
        self.density = density
        self.px = px; self.py = py; self.pz = pz
        self.sx = sx; self.sy = sy; self.sz = sz
        self.variance = variance
        self.steps = steps
    }
}

// v21: Weather particle effect (atmosphere).  Defaults match ParticleEffect so
// older project files load with weather disabled.
struct ParticleEffectData: Codable {
    var isEnabled: Bool  = false
    var type:      Int   = 0          // ParticleType raw (0=rain,1=snow,2=sleet,3=smoke)
    var px: Float = 0; var py: Float = 2; var pz: Float = 0
    var sx: Float = 8; var sy: Float = 5; var sz: Float = 8
    var density:  Float = 0.5
    var variance: Float = 0.5
    var r: Float = 1; var g: Float = 1; var b: Float = 1
    // v25; advanced controls.  Optional: nil (older files) → use the type defaults.
    var particleSize: Float? = nil
    var fallSpeed:    Float? = nil
    var streak:       Float? = nil
    var lifetime:     Float? = nil
    var growth:       Float? = nil
    var baseAlpha:    Float? = nil

    init(from decoder: Decoder) throws {
        let c     = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = (try? c.decode(Bool.self,  forKey: .isEnabled)) ?? false
        type      = (try? c.decode(Int.self,   forKey: .type))      ?? 0
        px = (try? c.decode(Float.self, forKey: .px)) ?? 0
        py = (try? c.decode(Float.self, forKey: .py)) ?? 2
        pz = (try? c.decode(Float.self, forKey: .pz)) ?? 0
        sx = (try? c.decode(Float.self, forKey: .sx)) ?? 8
        sy = (try? c.decode(Float.self, forKey: .sy)) ?? 5
        sz = (try? c.decode(Float.self, forKey: .sz)) ?? 8
        density  = (try? c.decode(Float.self, forKey: .density))  ?? 0.5
        variance = (try? c.decode(Float.self, forKey: .variance)) ?? 0.5
        r = (try? c.decode(Float.self, forKey: .r)) ?? 1
        g = (try? c.decode(Float.self, forKey: .g)) ?? 1
        b = (try? c.decode(Float.self, forKey: .b)) ?? 1
        particleSize = try? c.decode(Float.self, forKey: .particleSize)
        fallSpeed    = try? c.decode(Float.self, forKey: .fallSpeed)
        streak       = try? c.decode(Float.self, forKey: .streak)
        lifetime     = try? c.decode(Float.self, forKey: .lifetime)
        growth       = try? c.decode(Float.self, forKey: .growth)
        baseAlpha    = try? c.decode(Float.self, forKey: .baseAlpha)
    }

    init(isEnabled: Bool = false, type: Int = 0,
         px: Float = 0, py: Float = 2, pz: Float = 0,
         sx: Float = 8, sy: Float = 5, sz: Float = 8,
         density: Float = 0.5, variance: Float = 0.5,
         r: Float = 1, g: Float = 1, b: Float = 1,
         particleSize: Float? = nil, fallSpeed: Float? = nil, streak: Float? = nil,
         lifetime: Float? = nil, growth: Float? = nil, baseAlpha: Float? = nil) {
        self.isEnabled = isEnabled; self.type = type
        self.px = px; self.py = py; self.pz = pz
        self.sx = sx; self.sy = sy; self.sz = sz
        self.density = density; self.variance = variance
        self.r = r; self.g = g; self.b = b
        self.particleSize = particleSize; self.fallSpeed = fallSpeed; self.streak = streak
        self.lifetime = lifetime; self.growth = growth; self.baseAlpha = baseAlpha
    }
}

// v8: Background colour/gradient settings.  Defaults match BackgroundConfig initial values
// (solid black) so v1–v7 project files load with the standard black background.
struct BackgroundData: Codable {
    var mode:            Int   = 0      // BackgroundMode raw value: 0=solid, 1=gradient, 2=environment
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
    // v27: environment skybox brightness multiplier
    var environmentIntensity: Float = 1.0
    // v28: per-project Background HDR path (empty = mirror the lighting environment)
    var backgroundHDRPath:    String = ""
    // v30: vertical shift of the skybox backdrop (positive = up)
    var environmentHorizon:   Float = 0.0
    // Environment skybox excluded from the feedback loop (drawn fresh each frame).
    var excludeEnvironmentFromFeedback: Bool = false

    // Custom decoder so adding fields doesn't reset the whole background for older
    // files — each key is optional and falls back to its default when missing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode                 = (try? c.decode(Int.self,    forKey: .mode))                 ?? 0
        solidR               = (try? c.decode(Float.self,  forKey: .solidR))               ?? 0
        solidG               = (try? c.decode(Float.self,  forKey: .solidG))               ?? 0
        solidB               = (try? c.decode(Float.self,  forKey: .solidB))               ?? 0
        gradTopR             = (try? c.decode(Float.self,  forKey: .gradTopR))             ?? 0.05
        gradTopG             = (try? c.decode(Float.self,  forKey: .gradTopG))             ?? 0.06
        gradTopB             = (try? c.decode(Float.self,  forKey: .gradTopB))             ?? 0.14
        gradBottomR          = (try? c.decode(Float.self,  forKey: .gradBottomR))          ?? 0
        gradBottomG          = (try? c.decode(Float.self,  forKey: .gradBottomG))          ?? 0
        gradBottomB          = (try? c.decode(Float.self,  forKey: .gradBottomB))          ?? 0
        environmentIntensity = (try? c.decode(Float.self,  forKey: .environmentIntensity)) ?? 1.0
        backgroundHDRPath    = (try? c.decode(String.self, forKey: .backgroundHDRPath))    ?? ""
        environmentHorizon   = (try? c.decode(Float.self,  forKey: .environmentHorizon))   ?? 0.0
        excludeEnvironmentFromFeedback =
            (try? c.decode(Bool.self, forKey: .excludeEnvironmentFromFeedback)) ?? false
    }

    init(mode: Int = 0, solidR: Float = 0, solidG: Float = 0, solidB: Float = 0,
         gradTopR: Float = 0.05, gradTopG: Float = 0.06, gradTopB: Float = 0.14,
         gradBottomR: Float = 0, gradBottomG: Float = 0, gradBottomB: Float = 0,
         environmentIntensity: Float = 1.0, backgroundHDRPath: String = "",
         environmentHorizon: Float = 0.0, excludeEnvironmentFromFeedback: Bool = false) {
        self.mode = mode
        self.solidR = solidR; self.solidG = solidG; self.solidB = solidB
        self.gradTopR = gradTopR; self.gradTopG = gradTopG; self.gradTopB = gradTopB
        self.gradBottomR = gradBottomR; self.gradBottomG = gradBottomG; self.gradBottomB = gradBottomB
        self.environmentIntensity = environmentIntensity
        self.backgroundHDRPath = backgroundHDRPath
        self.environmentHorizon = environmentHorizon
        self.excludeEnvironmentFromFeedback = excludeEnvironmentFromFeedback
    }
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
    var mainWindow:          WindowFrameData  = WindowFrameData()  // always saved
    var timelineEditor:      WindowFrameData? = nil                // nil = was closed
    var lightsPanel:         WindowFrameData? = nil
    var feedbackPanel:       WindowFrameData? = nil
    var colorGradePanel:     WindowFrameData? = nil
    var cameraPanel:         WindowFrameData? = nil
    var modelInspectorPanel: WindowFrameData? = nil                // v15
    var atmospherePanel:     WindowFrameData? = nil                // v25
    var probeInspectorPanel: WindowFrameData? = nil                // v30+
    var effectsGrid:         WindowFrameData? = nil                // nil = was closed
    // v25; Atmosphere panel section expand/collapse state.  Optional so older
    // window-layout blobs still decode (nil → defaults on restore).
    var atmosphereFogExpanded:      Bool? = nil
    var atmosphereWeatherExpanded:  Bool? = nil
    var atmosphereAdvancedExpanded: Bool? = nil
}

struct TimelineData: Codable {
    var duration:    Double
    var currentTime: Double
    var frameRate:   Double = 30.0   // v20; absent in older files → 30 fps

    init(from decoder: Decoder) throws {
        let c       = try decoder.container(keyedBy: CodingKeys.self)
        duration    = try  c.decode(Double.self, forKey: .duration)
        currentTime = try  c.decode(Double.self, forKey: .currentTime)
        frameRate   = (try? c.decode(Double.self, forKey: .frameRate)) ?? 30.0
    }

    init(duration: Double, currentTime: Double, frameRate: Double = 30.0) {
        self.duration    = duration
        self.currentTime = currentTime
        self.frameRate   = frameRate
    }
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
    // v15: Model Inspector state.
    // isVisible defaults true; normalMode 0 = .auto.
    // metallicFactor / roughnessFactor: -1 = not overridden (use file value).
    // baseColorFactor: empty = not overridden.
    var isVisible:       Bool    = true
    // v17: holdout — when hidden, still occlude objects behind it (depth-only).
    var occludeWhenHidden: Bool  = false
    // Production class for "Export All" (rawValue: background/actor/macguffin).
    var objectClass:     String  = ObjectClass.background.rawValue
    // Per-object feedback opt-in (Effects grid).  Default true → older files keep
    // the previous "everything trails" behaviour.
    var feedbackEnabled: Bool    = true
    var normalMode:      Int     = 0
    var metallicFactor:  Float   = -1
    var roughnessFactor: Float   = -1
    var baseColorFactor: [Float] = []
    // User-controllable material opacity (0…1).  Default 1 → fully opaque, so
    // older project files without the field load with no behavioural change.
    var opacity:         Float   = 1
    // "Brightness": base-colour self-emission (0…1).  Default 0 → no glow, so older
    // files without the field load unchanged.
    var emissiveStrength: Float  = 0

    // Custom decoder so older files without the v15 fields decode cleanly.
    init(from decoder: Decoder) throws {
        let c                = try decoder.container(keyedBy: CodingKeys.self)
        name                 = try  c.decode(String.self,        forKey: .name)
        keyframes            = try  c.decode([KeyframeData].self, forKey: .keyframes)
        baseTransformMatrix  = (try? c.decode([Float].self,       forKey: .baseTransformMatrix)) ?? []
        easingMode           = (try? c.decode(Int.self,           forKey: .easingMode))          ?? 0
        isVisible            = (try? c.decode(Bool.self,          forKey: .isVisible))           ?? true
        occludeWhenHidden    = (try? c.decode(Bool.self,          forKey: .occludeWhenHidden))   ?? false
        objectClass          = (try? c.decode(String.self,        forKey: .objectClass))         ?? ObjectClass.background.rawValue
        feedbackEnabled      = (try? c.decode(Bool.self,          forKey: .feedbackEnabled))     ?? true
        normalMode           = (try? c.decode(Int.self,           forKey: .normalMode))          ?? 0
        metallicFactor       = (try? c.decode(Float.self,         forKey: .metallicFactor))      ?? -1
        roughnessFactor      = (try? c.decode(Float.self,         forKey: .roughnessFactor))     ?? -1
        baseColorFactor      = (try? c.decode([Float].self,       forKey: .baseColorFactor))     ?? []
        opacity              = (try? c.decode(Float.self,         forKey: .opacity))             ?? 1
        emissiveStrength     = (try? c.decode(Float.self,         forKey: .emissiveStrength))    ?? 0
    }

    init(name: String, keyframes: [KeyframeData],
         baseTransformMatrix: [Float] = [], easingMode: Int = 0,
         isVisible: Bool = true, occludeWhenHidden: Bool = false,
         objectClass: String = ObjectClass.background.rawValue,
         feedbackEnabled: Bool = true, normalMode: Int = 0,
         metallicFactor: Float = -1, roughnessFactor: Float = -1,
         baseColorFactor: [Float] = [], opacity: Float = 1,
         emissiveStrength: Float = 0) {
        self.name                = name
        self.keyframes           = keyframes
        self.baseTransformMatrix = baseTransformMatrix
        self.easingMode          = easingMode
        self.isVisible           = isVisible
        self.occludeWhenHidden   = occludeWhenHidden
        self.objectClass         = objectClass
        self.feedbackEnabled     = feedbackEnabled
        self.normalMode          = normalMode
        self.metallicFactor      = metallicFactor
        self.roughnessFactor     = roughnessFactor
        self.baseColorFactor     = baseColorFactor
        self.opacity             = opacity
        self.emissiveStrength    = emissiveStrength
    }
}

// One saved object keyframe — full TRS of the animation delta plus opacity.
// Quaternion stored as (rx=ix, ry=iy, rz=iz, rw=real) to match simd_quatf components.
// Opacity rides along with the transform so an object's fade is sampled at the
// same keyframe times as its motion; defaults to 1 for older project files.
struct KeyframeData: Codable {
    var time: Double
    // Translation
    var tx: Float; var ty: Float; var tz: Float
    // Rotation quaternion (ix, iy, iz, real)
    var rx: Float; var ry: Float; var rz: Float; var rw: Float
    // Scale
    var sx: Float; var sy: Float; var sz: Float
    // Opacity (added later — missing in old project files → defaults to 1).
    var opacity: Float = 1

    init(time: Double,
         tx: Float, ty: Float, tz: Float,
         rx: Float, ry: Float, rz: Float, rw: Float,
         sx: Float, sy: Float, sz: Float,
         opacity: Float = 1) {
        self.time = time
        self.tx = tx; self.ty = ty; self.tz = tz
        self.rx = rx; self.ry = ry; self.rz = rz; self.rw = rw
        self.sx = sx; self.sy = sy; self.sz = sz
        self.opacity = opacity
    }

    // Custom decoder so older project files (no `opacity` key) load cleanly.
    init(from decoder: Decoder) throws {
        let c    = try decoder.container(keyedBy: CodingKeys.self)
        time     = try  c.decode(Double.self, forKey: .time)
        tx       = try  c.decode(Float.self,  forKey: .tx)
        ty       = try  c.decode(Float.self,  forKey: .ty)
        tz       = try  c.decode(Float.self,  forKey: .tz)
        rx       = try  c.decode(Float.self,  forKey: .rx)
        ry       = try  c.decode(Float.self,  forKey: .ry)
        rz       = try  c.decode(Float.self,  forKey: .rz)
        rw       = try  c.decode(Float.self,  forKey: .rw)
        sx       = try  c.decode(Float.self,  forKey: .sx)
        sy       = try  c.decode(Float.self,  forKey: .sy)
        sz       = try  c.decode(Float.self,  forKey: .sz)
        opacity  = (try? c.decode(Float.self, forKey: .opacity)) ?? 1
    }
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
    /// Camera's forward direction (unit vector) in the followed object's
    /// local frame at creation time.  Preferred over yaw/pitch offsets for
    /// reconstructing camera orientation under arbitrary head rotation.
    /// nil / absent in older project files — loader falls back to the
    /// yaw/pitch offsets and the keyframe still resolves.
    var followForwardLocal: [Float]? = nil
    /// Camera's up direction (unit vector) in the followed object's local
    /// frame at creation time.  Set by POV keyframes so the camera rolls with
    /// the followed object on playback.  nil / absent in older project files
    /// → renderer uses world Y as up (the previous behaviour).
    var followUpLocal: [Float]? = nil

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
        fov                = try? c.decode(Float.self,   forKey: .fov)
        followTarget       = try? c.decode(String.self,  forKey: .followTarget)
        followYawOffset    = try? c.decode(Float.self,   forKey: .followYawOffset)
        followPitchOffset  = try? c.decode(Float.self,   forKey: .followPitchOffset)
        targetOffset       = try? c.decode([Float].self, forKey: .targetOffset)
        followForwardLocal = try? c.decode([Float].self, forKey: .followForwardLocal)
        followUpLocal      = try? c.decode([Float].self, forKey: .followUpLocal)
    }

    init(time: Double, yaw: Float, pitch: Float, distance: Float,
         targetX: Float, targetY: Float, targetZ: Float,
         fov: Float? = nil,
         followTarget: String? = nil,
         followYawOffset: Float? = nil,
         followPitchOffset: Float? = nil,
         targetOffset: [Float]? = nil,
         followForwardLocal: [Float]? = nil,
         followUpLocal: [Float]? = nil) {
        self.time               = time
        self.yaw                = yaw
        self.pitch              = pitch
        self.distance           = distance
        self.targetX            = targetX
        self.targetY            = targetY
        self.targetZ            = targetZ
        self.fov                = fov
        self.followTarget       = followTarget
        self.followYawOffset    = followYawOffset
        self.followPitchOffset  = followPitchOffset
        self.targetOffset       = targetOffset
        self.followForwardLocal = followForwardLocal
        self.followUpLocal      = followUpLocal
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
    var targetX:                 Float = 0.0     // v26: world-space aim target (was dirX/Y/Z)
    var targetY:                 Float = 0.0
    var targetZ:                 Float = 0.0
    var innerConeAngle:          Float = 0.3927  // π/8
    var outerConeAngle:          Float = 0.5236  // π/6
    var range:                   Float = 15.0
    var beamThickness:           Float = 1.0
    var excludeBeamFromFeedback: Bool  = false
}

// v6: One saved light keyframe — intensity, colour, target, position.
// v11: Added range and beamThickness.
// v26: aim now stored as a world-space target (was direction dx/dy/dz).
// Type, cone angles, and enabled state are not animated; restore them from LightConfig.
struct LightKeyframeData: Codable {
    var time:          Double
    var intensity:     Float
    // Colour components
    var r: Float; var g: Float; var b: Float
    // v26: world-space aim target (older files' dx/dy/dz are ignored → defaults)
    var tx: Float = 0; var ty: Float = 0; var tz: Float = 0
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
    /// Which instance of that filename (0-based, in load order) — distinguishes the
    /// same model loaded more than once.  Absent in older files → 0.
    var occurrence:     Int = 0
    /// EasingMode.rawValue — 0 = .linear.  Absent in older files → 0.
    var easingMode:     Int = 0
    /// The keyframe array for this group track.
    var keyframes:      [KeyframeData] = []

    init(sourceFileName: String, occurrence: Int = 0, easingMode: Int = 0,
         keyframes: [KeyframeData] = []) {
        self.sourceFileName = sourceFileName
        self.occurrence     = occurrence
        self.easingMode     = easingMode
        self.keyframes      = keyframes
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        sourceFileName = (try? c.decode(String.self,          forKey: .sourceFileName)) ?? ""
        occurrence     = (try? c.decode(Int.self,             forKey: .occurrence))     ?? 0
        easingMode     = (try? c.decode(Int.self,             forKey: .easingMode))     ?? 0
        keyframes      = (try? c.decode([KeyframeData].self,  forKey: .keyframes))      ?? []
    }
}

// Snapshot of `sceneManager.groupTransforms[gid]` for a group, keyed by the
// model's source filename (gids are runtime ephemeral).  Preserves Position/
// Rotation/Scale slider edits and Model-mode drags that wrote to `gt` but
// were never recorded as a keyframe — without this, an untracked group's
// `gt` is lost on save/load and the model snaps back to the auto-normalise
// size on reopen.  Tracked groups: the value is also saved but gets
// overwritten by track evaluation on the first frame, so it's a no-op there.
// Absent in older project files → loader skips and leaves `gt` at identity
// (the pre-fix behaviour).
struct GroupBaseTransformData: Codable {
    var sourceFileName: String
    /// Which instance of that filename (0-based, load order).  Absent in older files → 0.
    var occurrence:     Int = 0
    var matrix:         [Float]   // 16 floats, column-major

    init(sourceFileName: String, occurrence: Int = 0, matrix: [Float]) {
        self.sourceFileName = sourceFileName
        self.occurrence     = occurrence
        self.matrix         = matrix
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        sourceFileName = (try? c.decode(String.self,  forKey: .sourceFileName)) ?? ""
        occurrence     = (try? c.decode(Int.self,     forKey: .occurrence))     ?? 0
        matrix         = (try? c.decode([Float].self, forKey: .matrix))         ?? []
    }
}
