import simd

// Manages the scene's lights.
// Phase 1: one directional light + ambient.
// Future phases: multiple lights, keyframe animation, JSON serialisation.
final class LightManager {

    var primaryLight: LightConfig
    var ambientColor: SIMD3<Float>

    // Convenience accessor for shader upload
    var ambientColorVec4: SIMD4<Float> {
        return SIMD4<Float>(ambientColor, 0)
    }

    init() {
        primaryLight = .defaultDirectional
        ambientColor = SIMD3<Float>(0.08, 0.08, 0.12)

        if primaryLight.intensity <= 0 {
            print("[DEBUG] LightManager: primaryLight intensity is zero or negative")
        }
        print("[DEBUG] LightManager: initialized with default directional light, intensity=" + String(primaryLight.intensity))
    }
}
