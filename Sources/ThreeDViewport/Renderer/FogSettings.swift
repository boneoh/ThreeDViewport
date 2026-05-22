import Combine
import simd

// Observable model for the raymarched fog volume (atmosphere effects).
// Owned by ViewportView; read live by Renderer and VideoExporter each frame.
//
// A bounded, axis-aligned box of flat-coloured fog.  A fullscreen pass marches
// each camera ray through the box (clamped to scene depth), accumulating density
// with a soft edge falloff driven by `variance`, and composites the fog colour
// over the scene.  Shows in Color and Greyscale modes; Black + White matte mode
// leaves the matte solid white.
final class FogSettings: ObservableObject {

    /// Master enable.  When false the fog pass is skipped entirely.
    @Published var isEnabled: Bool = false

    /// Fog colour (display-space RGB, 0–1).  Default mid-grey.
    @Published var color: SIMD3<Float> = SIMD3<Float>(0.5, 0.5, 0.5)

    /// Overall density / opacity — higher = thicker fog.  0 = none.
    @Published var density: Float = 0.15

    /// Volume centre (world space).
    @Published var position: SIMD3<Float> = SIMD3<Float>(0, 1, 0)

    /// Volume size (world units, full extents).
    @Published var size: SIMD3<Float> = SIMD3<Float>(12, 4, 12)

    /// 0–1 edge softness.  0 = hard box; 1 = density fades fully toward the faces.
    @Published var variance: Float = 0.5

    /// Optional timeline animation.  nil / empty = use the static values above.
    /// Evaluated at render time (not written back to the @Published fields) so
    /// playback never marks the project dirty — matches object/camera animation.
    var keyframeTrack: AtmosphereKeyframeTrack?

    /// True while a keyframe is being live-edited from the panel.  The renderer
    /// then draws from the static fields (which the panel is editing) instead of
    /// the track, so slider changes show immediately at the paused playhead.
    var isEditingKeyframe: Bool = false

    /// Snapshot of the current static values as a keyframe at `time` (stamp source).
    func snapshot(at time: Double) -> AtmosphereKeyframe {
        AtmosphereKeyframe(time: time, position: position, size: size,
                           density: density, variance: variance, color: color)
    }

    /// Effective state at `time`: the static panel values while live-editing,
    /// the animated keyframe value if a track exists, otherwise the static values.
    func state(at time: Double) -> AtmosphereKeyframe {
        if isEditingKeyframe { return snapshot(at: time) }
        return keyframeTrack?.evaluate(at: time) ?? snapshot(at: time)
    }
}

/// Builds the GPU uniforms for the fog volume pass, resolving any timeline
/// animation at `time`.  Shared by Renderer and VideoExporter so preview and
/// export composite identically.
func makeFogVolumeUniforms(_ fog: FogSettings,
                           at time: Double,
                           viewProjection: matrix_float4x4,
                           cameraPos: SIMD3<Float>,
                           colorMode: Int) -> FogVolumeUniforms {
    let s    = fog.state(at: time)
    let half = s.size * 0.5
    return FogVolumeUniforms(
        inverseViewProjection: viewProjection.inverse,
        cameraPos: SIMD4<Float>(cameraPos, 0),
        boxMin:    SIMD4<Float>(s.position - half, 0),
        boxMax:    SIMD4<Float>(s.position + half, 0),
        color:     SIMD4<Float>(s.color, 1),
        density:   s.density,
        variance:  s.variance,
        colorMode: UInt32(colorMode))
}
