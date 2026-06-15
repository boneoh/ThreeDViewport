import Combine
import simd

// Procedural weather particle effect (Phase 2 of the atmosphere effects).
//
// Particles are deterministic functions of (seed, timeline-time): a static seed
// buffer is computed once, and the vertex shader derives each particle's current
// position from the time uniform — so the live preview, scrubbing, and the export
// all agree exactly.  Adapted from NVIDIA's smokeParticles concepts (gravity /
// turbulence / lifetime) into a closed-form, export-safe form.

/// Particle presets.  Rain/snow/sleet *fall and wrap*; smoke *rises over a
/// lifetime, grows, and fades*.  Each preset drives speed, particle size,
/// streak, and turbulence; the user tunes density / variance / color / volume.
enum ParticleType: Int, CaseIterable {
    case rain  = 0
    case snow  = 1
    case sleet = 2
    case smoke = 3

    var displayName: String {
        switch self {
        case .rain:  return "Rain"
        case .snow:  return "Snow"
        case .sleet: return "Sleet"
        case .smoke: return "Smoke"
        }
    }

    /// True for the rising/growing/fading lifecycle (vs falling-and-wrapping).
    var isSmoke: Bool { self == .smoke }

    /// Falling speed (world units / sec).  Unused by smoke (it derives rise from
    /// the volume height and lifetime).
    var fallSpeed: Float {
        switch self {
        case .rain:  return 7.0
        case .snow:  return 0.8
        case .sleet: return 3.5
        case .smoke: return 0.0
        }
    }

    /// Billboard half-size (world units).
    var particleSize: Float {
        switch self {
        case .rain:  return 0.012
        case .snow:  return 0.03
        case .sleet: return 0.016
        case .smoke: return 0.20
        }
    }

    /// Billboard length multiple along the fall direction (1 = round dot/puff).
    var streak: Float {
        switch self {
        case .rain:  return 8.0
        case .snow:  return 1.0
        case .sleet: return 3.5
        case .smoke: return 1.0
        }
    }

    /// Base lateral-turbulence amplitude (scaled by `variance`).
    var swayBase: Float {
        switch self {
        case .rain:  return 0.02
        case .snow:  return 0.30
        case .sleet: return 0.08
        case .smoke: return 0.6
        }
    }

    /// Smoke only — particle lifetime (seconds) over which it rises top-to-bottom.
    var lifetime: Float { isSmoke ? 4.0 : 0.0 }

    /// Smoke only — how much the puff grows over its lifetime (× particleSize).
    var growth: Float { isSmoke ? 4.0 : 0.0 }

    /// Per-particle base alpha.  Smoke is faint so overlapping puffs accumulate;
    /// falling weather is near-opaque.
    var baseAlpha: Float { isSmoke ? 0.16 : 1.0 }
}

// Observable model — owned by ViewportView, read live by Renderer and VideoExporter.
final class ParticleEffect: ObservableObject {
    @Published var isEnabled: Bool          = false
    /// Timeline edit lock — frozen against viewport edits + keyframe changes.
    /// @Published so the Atmosphere panel disables this emitter's controls reactively.
    @Published var isLocked: Bool = false
    @Published var type:      ParticleType  = .rain {
        didSet { if type != oldValue { applyTypeDefaults() } }   // Type acts as a preset.
    }
    /// Emitter volume centre (world space).
    @Published var position:  SIMD3<Float>  = SIMD3<Float>(0, 2, 0)
    /// Emitter volume size (world units, full extents).
    @Published var size:      SIMD3<Float>  = SIMD3<Float>(8, 5, 8)
    /// 0–1 fraction of the max particle pool that's drawn.
    @Published var density:   Float         = 0.5
    /// 0–1 lateral turbulence amount.
    @Published var variance:  Float         = 0.5
    /// Particle colour (display-space RGB).
    @Published var color:     SIMD3<Float>  = SIMD3<Float>(1, 1, 1)

    // ── Advanced controls (Phase 4) ─────────────────────────────────────────
    // Defaulted from `type`; reset to the new type's defaults when the type
    // changes (applyTypeDefaults).  Static config — not keyframed.
    @Published var particleSize: Float = ParticleType.rain.particleSize
    @Published var fallSpeed:    Float = ParticleType.rain.fallSpeed   // falling types
    @Published var streak:       Float = ParticleType.rain.streak      // falling types
    @Published var lifetime:     Float = ParticleType.rain.lifetime    // smoke
    @Published var growth:       Float = ParticleType.rain.growth      // smoke
    @Published var baseAlpha:    Float = ParticleType.rain.baseAlpha   // smoke opacity

    /// Resets the advanced controls to the current type's preset defaults.
    func applyTypeDefaults() {
        particleSize = type.particleSize
        fallSpeed    = type.fallSpeed
        streak       = type.streak
        lifetime     = type.lifetime
        growth       = type.growth
        baseAlpha    = type.baseAlpha
    }

    /// Optional timeline animation.  nil / empty = use the static values above.
    /// Evaluated at render time (not written back) so playback never marks dirty.
    var keyframeTrack: AtmosphereKeyframeTrack?

    /// Set when this emitter was brought in by File ▸ Import Project, so the Timeline
    /// groups it under the import's bundle header and the bundle's move/loop apply to
    /// its keyframe times.  nil = a host emitter.
    var importBundleID: Int? = nil

    /// Timeline duration, set by the renderer/exporter each frame, used as the cutoff
    /// so keyframes left beyond a shortened timeline don't pull the in-range animation.
    var evaluationCutoff: Double? = nil

    /// Set while `syncToPlayhead` writes the static fields so the dirty sink can
    /// ignore it — scrubbing follows the animation without marking dirty.
    var suppressDirty: Bool = false

    /// Snapshot of the current static values as a keyframe at `time` (stamp source).
    func snapshot(at time: Double) -> AtmosphereKeyframe {
        AtmosphereKeyframe(time: time, position: position, size: size,
                           density: density, variance: variance, color: color)
    }

    /// Value used to render at `time` (see FogSettings.renderState).  Playing →
    /// keyframes drive it; paused → the static panel fields (kept in sync by
    /// `syncToPlayhead`) so the panel and viewport agree.
    func renderState(at time: Double, playing: Bool) -> AtmosphereKeyframe {
        if playing, let kf = keyframeTrack?.evaluate(at: time, cutoff: evaluationCutoff) { return kf }
        return snapshot(at: time)
    }

    /// While paused, copy the resolved keyframe value at `time` into the static
    /// fields so the panel + paused render follow the playhead (see FogSettings).
    func syncToPlayhead(at time: Double) {
        guard let kf = keyframeTrack?.evaluate(at: time, cutoff: evaluationCutoff) else { return }
        suppressDirty = true
        position = kf.position; size = kf.size; density = kf.density
        variance = kf.variance; color = kf.color
        suppressDirty = false
    }

    /// Maximum particle pool — `density` selects a fraction of this to draw.
    static let maxCount = 4000

    /// Deterministic seed pool: (x, y, z) in [0,1] within the unit volume, plus a
    /// phase in [0,1).  Generated identically (fixed seed) in renderer and exporter.
    static func makeSeeds(count: Int = maxCount) -> [SIMD4<Float>] {
        var state: UInt64 = 0x9E3779B97F4A7C15   // fixed seed → reproducible
        func next() -> Float {
            // SplitMix64 → [0,1)
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            z =  z ^ (z >> 31)
            return Float(z >> 40) / Float(1 << 24)   // 24-bit mantissa → [0,1)
        }
        return (0..<count).map { _ in SIMD4<Float>(next(), next(), next(), next()) }
    }
}

/// Builds the GPU uniforms for the particle pass, resolving any timeline
/// animation of the emitter (position / size / variance / colour) at `time`.
/// Shared by Renderer and VideoExporter so preview and export stay identical.
func makeParticleFXUniforms(_ fx: ParticleEffect,
                            viewProjection: matrix_float4x4,
                            cameraRight: SIMD3<Float>,
                            cameraUp: SIMD3<Float>,
                            time: Float,
                            playing: Bool,
                            colorMode: Int) -> ParticleFXUniforms {
    let s = fx.renderState(at: Double(time), playing: playing)
    return ParticleFXUniforms(
        viewProjection: viewProjection,
        cameraRight:    SIMD4<Float>(cameraRight, 0),
        cameraUp:       SIMD4<Float>(cameraUp, 0),
        emitterCenter:  SIMD4<Float>(s.position, 0),
        emitterSize:    SIMD4<Float>(s.size, 0),
        color:          SIMD4<Float>(s.color, 1),
        time:           time,
        fallSpeed:      fx.fallSpeed,
        particleSize:   fx.particleSize,
        streak:         fx.streak,
        sway:           fx.type.swayBase * s.variance,
        swayFreq:       1.5,
        colorMode:      UInt32(colorMode),
        mode:           fx.type.isSmoke ? 1 : 0,
        growth:         fx.growth,
        lifetime:       fx.lifetime,
        baseAlpha:      fx.baseAlpha)
}

