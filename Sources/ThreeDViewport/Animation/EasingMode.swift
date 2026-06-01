import simd

// MARK: - EasingMode

/// Per-track interpolation mode for KeyframeTrack.
/// Int raw value so it serialises directly to the project file as an integer.
/// Add new cases at the end only — existing raw values must stay stable.
///
///   0 = linear   plain lerp / slerp (default)
///   1 = smooth   Catmull-Rom spline path, standard tension (τ=0.5 / squad)
///   2 = splineS  Catmull-Rom spline path, subtle  tension (τ=0.25 / half-squad)
///   3 = splineM  Catmull-Rom spline path, medium  tension (τ=0.5  / full squad)  ← same math as smooth
///   4 = splineL  Catmull-Rom spline path, wide    tension (τ=1.0  / double squad)
///
/// Note: raw values 2 and 3 previously held "snap" and "elastic"; project files
/// that stored those values silently upgrade to splineS / splineM on load.
enum EasingMode: Int, Codable, CaseIterable {
    case linear  = 0
    case smooth  = 1
    case splineS = 2
    case splineM = 3
    case splineL = 4

    var displayName: String {
        switch self {
        case .linear:  return "Linear"
        case .smooth:  return "Smooth"
        case .splineS: return "Spline S"
        case .splineM: return "Spline M"
        case .splineL: return "Spline L"
        }
    }
}

// MARK: - Easing math

extension EasingMode {

    // ── Catmull-Rom for SIMD3<Float> (used by .smooth) ───────────────────────
    // Standard uniform Catmull-Rom (tension τ = 0.5 baked into coefficients).
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

    // ── Catmull-Rom for SIMD3<Float> with explicit tension (used by splineS/M/L) ─
    // Hermite form: tangent at p1 = tension*(p2−p0), tangent at p2 = tension*(p3−p1).
    // tension=0.5 → identical to catmullRom above (standard CR).
    // tension=0.25 → subtle arc; tension=1.0 → wide arc.
    static func catmullRomTensioned(_ p0: SIMD3<Float>,
                                     _ p1: SIMD3<Float>,
                                     _ p2: SIMD3<Float>,
                                     _ p3: SIMD3<Float>,
                                     t: Float, tension: Float) -> SIMD3<Float> {
        let t2 = t * t
        let t3 = t2 * t
        let m1 = tension * (p2 - p0)   // tangent at p1
        let m2 = tension * (p3 - p1)   // tangent at p2
        return ( 2*t3 - 3*t2 + 1) * p1
             + (   t3 - 2*t2 + t) * m1
             + (-2*t3 + 3*t2    ) * p2
             + (   t3 -   t2    ) * m2
    }

    // ── Catmull-Rom for Float (camera/light/effect scalar channels) ──────────
    // Same Hermite form as the SIMD3 version, for scalar tracks (yaw, pitch,
    // distance, fov, intensity, range, density, …).
    static func catmullRomTensioned(_ p0: Float, _ p1: Float, _ p2: Float, _ p3: Float,
                                     t: Float, tension: Float) -> Float {
        let t2 = t * t
        let t3 = t2 * t
        let m1 = tension * (p2 - p0)
        let m2 = tension * (p3 - p1)
        return ( 2*t3 - 3*t2 + 1) * p1
             + (   t3 - 2*t2 + t) * m1
             + (-2*t3 + 3*t2    ) * p2
             + (   t3 -   t2    ) * m2
    }

    /// Position tension for a spline easing mode (matches the object track tiers).
    /// nil = not a spline mode (caller should lerp linearly).
    var splinePosTension: Float? {
        switch self {
        case .linear:  return nil
        case .splineS: return 0.25
        case .smooth, .splineM: return 0.5
        case .splineL: return 1.0
        }
    }

    // ── Quaternion helpers for squadTensioned ─────────────────────────────────

    /// Logarithm of a unit quaternion → pure imaginary 3-vector (θ·n).
    static func qLog(_ q: simd_quatf) -> SIMD3<Float> {
        let v    = q.imag
        let w    = min(max(q.real, -1.0), 1.0)   // clamp for numerical safety
        let vLen = simd_length(v)
        guard vLen > 1e-7 else { return .zero }
        return (acos(w) / vLen) * v
    }

    /// Exponential map: pure imaginary 3-vector → unit quaternion.
    static func qExp(_ v: SIMD3<Float>) -> simd_quatf {
        let theta = simd_length(v)
        guard theta > 1e-7 else { return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }
        let s = sin(theta) / theta
        return simd_quatf(ix: v.x * s, iy: v.y * s, iz: v.z * s, r: cos(theta))
    }

    /// Returns q negated if it is on the opposite hemisphere from ref,
    /// ensuring simd_slerp takes the short arc.
    static func qFlip(_ q: simd_quatf, like ref: simd_quatf) -> simd_quatf {
        simd_dot(q.vector, ref.vector) >= 0
            ? q
            : simd_quatf(ix: -q.imag.x, iy: -q.imag.y, iz: -q.imag.z, r: -q.real)
    }

    // ── Spherical cubic spline (squad) with explicit tension ──────────────────
    // Quaternion analogue of catmullRomTensioned.
    // tension=1.0 → standard squad (same result as simd_spline).
    // tension=0.5 → half curvature (path arcs less).
    // tension=2.0 → double curvature (path arcs more).
    //
    // Inner control points:
    //   s_i = q_i · exp(−tension·0.25 · (log(q_i⁻¹·q_{i+1}) + log(q_i⁻¹·q_{i-1})))
    //
    // Squad formula:
    //   squad(q1,q2,s1,s2,t) = slerp(slerp(q1,q2,t), slerp(s1,s2,t), 2t(1−t))
    static func squadTensioned(_ q0: simd_quatf, _ q1: simd_quatf,
                                _ q2: simd_quatf, _ q3: simd_quatf,
                                t: Float, tension: Float) -> simd_quatf {
        // Flip all neighbours into the same hemisphere as q1 / q2 to guarantee
        // simd_slerp always takes the short arc.
        let f0 = qFlip(q0, like: q1)
        let f2 = qFlip(q2, like: q1)
        let f3 = qFlip(q3, like: f2)

        let scale = tension * 0.25

        // Inner control point adjacent to q1
        let s1 = q1 * qExp(-scale * (qLog(q1.inverse * f2) + qLog(q1.inverse * f0)))

        // Inner control point adjacent to q2
        let s2 = f2 * qExp(-scale * (qLog(f2.inverse * f3) + qLog(f2.inverse * q1)))

        // De Casteljau squad evaluation
        return simd_slerp(
            simd_slerp(q1, f2, t),
            simd_slerp(s1, s2, t),
            2.0 * t * (1.0 - t)
        )
    }
}
