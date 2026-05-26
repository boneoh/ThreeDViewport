import simd

/// Transform helpers used by the Model Inspector for rotation editing.
///
/// Euler convention: **YXZ intrinsic** (R = Ry · Rx · Rz), degrees.  Chosen so
/// the Y slider (yaw) covers the full ±180° range — the asin-bound axis is X
/// (pitch, ±90°), which is the typical use.  Decomposition is deterministic
/// (a given matrix always yields the same Euler), so copy/paste round-trips.
enum TransformMath {

    /// Builds a pure-rotation 4×4 matrix from YXZ Euler degrees.
    static func matrixFromEuler(_ degrees: SIMD3<Float>) -> matrix_float4x4 {
        let r = degrees * (.pi / 180.0)
        let cx = cos(r.x), sx = sin(r.x)
        let cy = cos(r.y), sy = sin(r.y)
        let cz = cos(r.z), sz = sin(r.z)
        // R = Ry · Rx · Rz  (column-vector convention).
        let col0 = SIMD4<Float>( cy * cz + sy * sx * sz,  cx * sz, -sy * cz + cy * sx * sz, 0)
        let col1 = SIMD4<Float>(-cy * sz + sy * sx * cz,  cx * cz,  sy * sz + cy * sx * cz, 0)
        let col2 = SIMD4<Float>( sy * cx,                 -sx,      cy * cx,                0)
        let col3 = SIMD4<Float>(0, 0, 0, 1)
        return matrix_float4x4(columns: (col0, col1, col2, col3))
    }

    /// Decomposes the rotation portion of a transform to YXZ Euler degrees.
    /// Normalises columns first to strip out any baked-in scale.
    static func eulerFromMatrix(_ m: matrix_float4x4) -> SIMD3<Float> {
        let (n0, n1, n2) = normalizedColumns(m)
        // R[r][c] = n_c[r] in column-major form, so:
        //   R[1][2] = n2.y  → sx = -R[1][2] = -n2.y
        let sx = simd_clamp(-n2.y, -1, 1)
        let x  = asin(sx)
        let y: Float, z: Float
        if abs(sx) < 0.9999 {
            y = atan2( n2.x,  n2.z)     // = atan2(R[0][2], R[2][2])
            z = atan2( n0.y,  n1.y)     // = atan2(R[1][0], R[1][1])
        } else {
            // Gimbal lock — fix Z and recover Y from the remaining rotation.
            z = 0
            y = atan2( n1.x,  n0.x)     // = atan2(R[0][1], R[0][0])
        }
        return SIMD3<Float>(x, y, z) * (180.0 / .pi)
    }

    /// Extracts non-uniform column scales from the upper-3×3 of a transform.
    static func scale(of m: matrix_float4x4) -> SIMD3<Float> {
        let (c0, c1, c2) = columns3(m)
        return SIMD3<Float>(simd_length(c0), simd_length(c1), simd_length(c2))
    }

    /// Returns a copy of `m` with its upper-3×3 set to `R · diag(scale)` and its
    /// translation column preserved.  Used to apply a new rotation while keeping
    /// the object's scale and position.
    static func applying(rotation R: matrix_float4x4,
                         scale s: SIMD3<Float>,
                         to m: matrix_float4x4) -> matrix_float4x4 {
        let oldT = m.columns.3
        let c0 = SIMD4<Float>(R.columns.0.x * s.x, R.columns.0.y * s.x, R.columns.0.z * s.x, 0)
        let c1 = SIMD4<Float>(R.columns.1.x * s.y, R.columns.1.y * s.y, R.columns.1.z * s.y, 0)
        let c2 = SIMD4<Float>(R.columns.2.x * s.z, R.columns.2.y * s.z, R.columns.2.z * s.z, 0)
        return matrix_float4x4(columns: (c0, c1, c2, oldT))
    }

    /// Pure-rotation 4×4 matrix (upper-3×3 normalised, translation = 0).
    static func pureRotation(of m: matrix_float4x4) -> matrix_float4x4 {
        let (c0, c1, c2) = columns3(m)
        let s0 = simd_length(c0), s1 = simd_length(c1), s2 = simd_length(c2)
        guard s0 > 1e-6, s1 > 1e-6, s2 > 1e-6 else { return matrix_identity_float4x4 }
        let n0 = c0 / s0, n1 = c1 / s1, n2 = c2 / s2
        return matrix_float4x4(columns: (
            SIMD4<Float>(n0, 0),
            SIMD4<Float>(n1, 0),
            SIMD4<Float>(n2, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }

    /// A pure-translation 4×4 matrix.
    static func translation(_ t: SIMD3<Float>) -> matrix_float4x4 {
        matrix_float4x4(columns: (
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(t.x, t.y, t.z, 1)
        ))
    }

    // MARK: - Private

    private static func columns3(_ m: matrix_float4x4)
        -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
        return (
            SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z),
            SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z),
            SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        )
    }

    private static func normalizedColumns(_ m: matrix_float4x4)
        -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
        let (c0, c1, c2) = columns3(m)
        let s0 = simd_length(c0), s1 = simd_length(c1), s2 = simd_length(c2)
        let safe: (SIMD3<Float>, Float) -> SIMD3<Float> = { v, s in
            s > 1e-6 ? v / s : SIMD3<Float>(0, 0, 0)
        }
        return (safe(c0, s0), safe(c1, s1), safe(c2, s2))
    }
}
