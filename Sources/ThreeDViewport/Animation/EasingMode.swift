import simd

// MARK: - EasingMode

/// Per-track interpolation mode for KeyframeTrack.
/// Int raw value so it serialises directly to the project file as an integer.
/// Add new cases at the end only — existing raw values must stay stable.
///
///   0 = linear   plain lerp / slerp (default, existing behaviour)
///   1 = smooth   Catmull-Rom auto-smooth through every keyframe
///   2 = snap     tanh S-curve: slow → fast burst → slow
///   3 = elastic  back-ease out: overshoots target ~10 % then settles
enum EasingMode: Int, Codable, CaseIterable {
    case linear  = 0
    case smooth  = 1
    case snap    = 2
    case elastic = 3

    var displayName: String {
        switch self {
        case .linear:  return "Linear"
        case .smooth:  return "Smooth"
        case .snap:    return "Snap"
        case .elastic: return "Elastic"
        }
    }
}

// MARK: - Easing math

extension EasingMode {

    // ── Snap ─────────────────────────────────────────────────────────────────
    // Remaps t ∈ [0,1] through a scaled tanh S-curve.
    // k controls sharpness: 1 ≈ gentle, 4 = punchy snap, 8 ≈ near-instant.
    private static let snapK: Float = 4.0

    static func snapT(_ t: Float) -> Float {
        let k     = snapK
        let tanhK = tanh(k)
        return (tanh(k * (2.0 * t - 1.0)) + tanhK) / (2.0 * tanhK)
    }

    // ── Elastic (back-ease out) ───────────────────────────────────────────────
    // Overshoots the destination by ~10 % then settles exactly on it.
    // Standard Penner/easings.net back-ease-out constants.
    private static let c1: Float = 1.70158          // overshoot amount
    private static let c3: Float = 1.70158 + 1.0    // c1 + 1

    static func elasticT(_ t: Float) -> Float {
        let t1 = t - 1.0
        return 1.0 + c3 * t1 * t1 * t1 + c1 * t1 * t1
    }

    // ── Catmull-Rom for SIMD3<Float> ─────────────────────────────────────────
    // Uniform Catmull-Rom interpolation between p1 and p2 given surrounding
    // control points p0 (before p1) and p3 (after p2).  t ∈ [0,1].
    static func catmullRom(_ p0: SIMD3<Float>,
                           _ p1: SIMD3<Float>,
                           _ p2: SIMD3<Float>,
                           _ p3: SIMD3<Float>,
                           t: Float) -> SIMD3<Float> {
        let t2  = t * t
        let t3  = t2 * t
        let a0  = 2.0 * p1
        let a1  = (-p0 + p2) * t
        let a2  = (2.0*p0 - 5.0*p1 + 4.0*p2 - p3) * t2
        let a3  = (-p0 + 3.0*p1 - 3.0*p2 + p3)    * t3
        return 0.5 * (a0 + a1 + a2 + a3)
    }
}
