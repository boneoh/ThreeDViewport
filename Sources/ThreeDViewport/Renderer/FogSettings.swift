import Combine
import simd

// Observable model for distance fog (Phase 1 of the atmosphere effects).
// Owned by ViewportView; read live by Renderer and VideoExporter each frame.
//
// Exponential distance fog: a fragment's lit colour is blended toward `color`
// based on its distance from the camera — fogFactor = 1 - exp(-density · (d - start)).
// Applied in the scene shader before the greyscale/B+W conversion, so it shows in
// Color and Greyscale modes; Black + White matte mode overrides it with solid white.
final class FogSettings: ObservableObject {

    /// Master enable.  When false the shader skips fog entirely.
    @Published var isEnabled: Bool = false

    /// Fog colour (display-space RGB, 0–1).  Default mid-grey.
    @Published var color: SIMD3<Float> = SIMD3<Float>(0.5, 0.5, 0.5)

    /// Exponential density — higher = thicker fog.  0 = none.
    @Published var density: Float = 0.15

    /// Distance (world units) before fog begins, keeping the foreground clear.
    @Published var startDistance: Float = 0.0

    /// GPU-ready uniforms for the scene shader.
    var uniforms: FogUniforms {
        FogUniforms(color:   color,
                    density: density,
                    start:   startDistance,
                    enabled: isEnabled ? 1 : 0)
    }

    /// Disabled fog — used when no FogSettings is wired up.
    static let disabledUniforms = FogUniforms(color: SIMD3<Float>(repeating: 0),
                                              density: 0, start: 0, enabled: 0)
}
