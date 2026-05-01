import simd

// Configuration for a single directional light.
// Phase 2 will add keyframe animation; Phase 4 will serialise to JSON.
struct LightConfig {

    var direction: SIMD3<Float>   // World-space direction the light points
    var color: SIMD3<Float>       // Linear RGB
    var intensity: Float

    // MARK: - Convenience accessors for shader upload (float4 with w=0)

    var directionVec4: SIMD4<Float> {
        return SIMD4<Float>(direction, 0)
    }

    var colorVec4: SIMD4<Float> {
        return SIMD4<Float>(color * intensity, 0)
    }

    // MARK: - Defaults

    static var defaultDirectional: LightConfig {
        return LightConfig(
            direction: simd_normalize(SIMD3<Float>(1.0, -1.5, -1.0)),
            color: SIMD3<Float>(1.0, 0.98, 0.95),
            intensity: 1.0
        )
    }
}
