import simd

// Phase 2 placeholder — interpolation helpers for animation.
// Will support linear, step, and cubic-spline (GLTF spec).
enum InterpolationMode {
    case linear
    case step
    case cubicSpline   // Phase 2
}

struct Interpolation {

    // Linear blend between two Float values
    static func lerp(from a: Float, to b: Float, t: Float) -> Float {
        return a + (b - a) * t
    }

    // Linear blend between two SIMD3<Float> values
    static func lerp(from a: SIMD3<Float>, to b: SIMD3<Float>, t: Float) -> SIMD3<Float> {
        return a + (b - a) * t
    }

    // Spherical linear interpolation for quaternions
    static func slerp(from a: simd_quatf, to b: simd_quatf, t: Float) -> simd_quatf {
        return simd_slerp(a, b, t)
    }
}
