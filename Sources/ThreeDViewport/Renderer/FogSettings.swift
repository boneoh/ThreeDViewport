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

    /// Set while `syncToPlayhead` writes the static fields so the AppDelegate dirty
    /// sink can ignore it — scrubbing follows the animation without marking dirty.
    var suppressDirty: Bool = false

    /// Snapshot of the current static values as a keyframe at `time` (stamp source).
    func snapshot(at time: Double) -> AtmosphereKeyframe {
        AtmosphereKeyframe(time: time, position: position, size: size,
                           density: density, variance: variance, color: color)
    }

    /// Value used to render at `time`.  While the timeline plays, the keyframes
    /// drive the render (and the export).  While paused, the static panel fields
    /// drive it — and `syncToPlayhead` keeps those fields equal to the keyframe
    /// value at the current frame, so the panel + viewport always agree and a
    /// stamp captures exactly what's on screen.
    func renderState(at time: Double, playing: Bool) -> AtmosphereKeyframe {
        if playing, let kf = keyframeTrack?.evaluate(at: time) { return kf }
        return snapshot(at: time)
    }

    /// While paused, copy the resolved keyframe value at `time` into the static
    /// fields so the panel and the paused render follow the playhead.  No-op when
    /// there's no track.  Suppresses the dirty flag so scrubbing stays clean.
    func syncToPlayhead(at time: Double) {
        guard let kf = keyframeTrack?.evaluate(at: time) else { return }
        suppressDirty = true
        position = kf.position; size = kf.size; density = kf.density
        variance = kf.variance; color = kf.color
        suppressDirty = false
    }
}

/// Builds the GPU uniforms for the fog volume pass, resolving any timeline
/// animation at `time`.  Shared by Renderer and VideoExporter so preview and
/// export composite identically.
func makeFogVolumeUniforms(_ fog: FogSettings,
                           at time: Double,
                           playing: Bool,
                           viewProjection: matrix_float4x4,
                           cameraPos: SIMD3<Float>,
                           colorMode: Int) -> FogVolumeUniforms {
    let s    = fog.renderState(at: time, playing: playing)
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
