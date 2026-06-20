import simd

// Phase 7: light type — maps to the integer stored in ShaderLight.position.w.
enum LightType: Int, CaseIterable {
    case ambient     = 0
    case directional = 1
    case point       = 2   // omnidirectional from a position ("pin")
    case spot        = 3   // cone from a position toward a direction
    case laser       = 4   // narrow hard-edge beam

    var displayName: String {
        switch self {
        case .ambient:     return "Ambient"
        case .directional: return "Directional"
        case .point:       return "Point"
        case .spot:        return "Spot"
        case .laser:       return "Laser"
        }
    }

    var systemImage: String {
        switch self {
        case .ambient:     return "sun.max.fill"
        case .directional: return "arrow.down.left"
        case .point:       return "pin.fill"
        case .spot:        return "flashlight.on.fill"
        case .laser:       return "bolt.fill"
        }
    }
}

// Configuration for a single light of any type.
struct LightConfig {

    var type:      LightType     = .directional
    var isEnabled: Bool          = true
    /// Timeline edit lock — frozen against viewport edits + keyframe changes.
    var isLocked:  Bool          = false
    /// User-chosen display name (Timeline right-click ▸ Rename).  nil = default
    /// "Light N - Type".
    var customName: String?      = nil

    // ── Shared ───────────────────────────────────────────────────────────────
    var color:     SIMD3<Float>  = SIMD3<Float>(1.0, 1.0, 1.0)
    var intensity: Float         = 1.0

    // ── Positional lights (point / spot / laser) ──────────────────────────────
    var position:  SIMD3<Float>  = SIMD3<Float>(0, 3, 3)

    // ── Aim target (directional / spot / laser) ───────────────────────────────
    // The light aims from `position` toward `target`; `direction` is derived.
    // For directional lights, position/target are only aiming handles — lighting
    // uses the derived (parallel-ray) direction, not the position itself.
    var target:    SIMD3<Float>  = SIMD3<Float>(0, 0, 0)

    // ── Spot / laser — half-angles in radians ─────────────────────────────────
    var innerConeAngle: Float    = Float.pi / 8.0    // 22.5°
    var outerConeAngle: Float    = Float.pi / 6.0    // 30°

    // ── Point / spot / laser ──────────────────────────────────────────────────
    var range: Float             = 15.0

    // ── Laser beam visuals ────────────────────────────────────────────────────
    /// Visible beam width in pixels.  1 = single-pixel line; ≥2 = billboard quad.
    var beamThickness: Float     = 1.0
    /// When true the beam is drawn after the feedback composite pass so it is
    /// never captured in the delay-line ring buffer (no trailing copies).
    var excludeBeamFromFeedback: Bool = false

    /// Display-only "import bundle" tag (Phase 2 Part B): lights brought in by one
    /// File ▸ Import Project (with Include lights) share a bundle ID so the Timeline
    /// Editor can fold their lanes under the bundle header.  Nil = not bundled.
    var importBundleID: Int? = nil

    // ── Derived aim direction ─────────────────────────────────────────────────
    /// Unit vector from `position` toward `target`.  Setting it moves `target`
    /// along the new direction, preserving the current position→target distance
    /// (falling back to `range` when they coincide).  Read by shaders, gizmos,
    /// and the laser beam; the setter lets keyboard aim (rotate/reset) stay as-is.
    var direction: SIMD3<Float> {
        get {
            let d   = target - position
            let len = simd_length(d)
            return len > 1e-5 ? d / len : SIMD3<Float>(0, -1, 0)
        }
        set {
            let len = simd_length(newValue)
            guard len > 1e-5 else { return }
            let unit    = newValue / len
            let dist    = simd_length(target - position)
            let useDist = dist > 1e-5 ? dist : (range > 1e-5 ? range : 1.0)
            target = position + unit * useDist
        }
    }

    // MARK: - Shader accessors

    // position xyz + w = light type
    var positionVec4: SIMD4<Float> {
        return SIMD4<Float>(position, Float(type.rawValue))
    }

    // direction xyz (normalised), w unused
    var directionVec4: SIMD4<Float> {
        return SIMD4<Float>(simd_normalize(direction), 0)
    }

    // color × intensity in xyz, raw intensity in w
    var colorVec4: SIMD4<Float> {
        return SIMD4<Float>(color * intensity, intensity)
    }

    // x = cos(inner), y = cos(outer), z = range, w = 0
    var paramsVec4: SIMD4<Float> {
        return SIMD4<Float>(cos(innerConeAngle), cos(outerConeAngle), range, 0)
    }

    // Convenience: build ShaderLight for this config
    var shaderLight: ShaderLight {
        var sl = ShaderLight()
        sl.position  = positionVec4
        sl.direction = directionVec4
        sl.color     = colorVec4
        sl.params    = paramsVec4
        return sl
    }

    // MARK: - Defaults

    static var defaultDirectional: LightConfig {
        var l = LightConfig()
        l.type      = .directional
        l.position  = SIMD3<Float>(0, 3, 3)
        l.target    = l.position + simd_normalize(SIMD3<Float>(0.5, -1.2, -0.8)) * l.range
        l.color     = SIMD3<Float>(1.0, 0.98, 0.95)
        l.intensity = 1.2
        return l
    }

    static var defaultAmbient: LightConfig {
        var l = LightConfig()
        l.type      = .ambient
        l.color     = SIMD3<Float>(1.0, 1.0, 1.0)
        l.intensity = 0.2
        return l
    }

    static var defaultPoint: LightConfig {
        var l = LightConfig()
        l.type      = .point
        l.color     = SIMD3<Float>(1.0, 0.9, 0.75)
        l.intensity = 3.0
        l.position  = SIMD3<Float>(2, 3, 2)
        l.range     = 15.0
        return l
    }

    static var defaultSpot: LightConfig {
        var l = LightConfig()
        l.type           = .spot
        l.color          = SIMD3<Float>(1.0, 0.95, 0.85)
        l.intensity      = 4.0
        l.position       = SIMD3<Float>(0, 4, 2)
        l.innerConeAngle = Float.pi / 8.0    // 22.5°
        l.outerConeAngle = Float.pi / 5.5    // ~33°
        l.range          = 15.0
        l.target         = l.position + simd_normalize(SIMD3<Float>(0, -1, -0.4)) * l.range
        return l
    }

    static var defaultLaser: LightConfig {
        var l = LightConfig()
        l.type                    = .laser
        l.color                   = SIMD3<Float>(0.15, 0.8, 1.0)   // cyan-blue
        l.intensity               = 10.0
        l.position                = SIMD3<Float>(0, 3, 3)
        l.innerConeAngle          = 0.013               // ≈ 0.75° — hard pencil beam
        l.outerConeAngle          = 0.026               // ≈ 1.5°
        l.range                   = 30.0
        l.target                  = l.position + simd_normalize(SIMD3<Float>(0, -0.4, -1)) * l.range
        l.beamThickness           = 3.0
        l.excludeBeamFromFeedback = false
        return l
    }
}
