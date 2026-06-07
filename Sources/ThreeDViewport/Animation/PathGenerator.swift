import simd

/// Pure geometry for the Path Animator helper: samples a helix / arc around a
/// central axis defined by two Probe points.  No UI or scene dependencies, so the
/// math can be reasoned about (and unit-tested) in isolation.
///
/// Path: `θ(s) = startAngle + s·Δθ`, `Δθ = (endAngle − startAngle) + revolutions·360°`,
/// `P(s) = A + s·(B − A) + radius·(cos θ·u + sin θ·v)` for s ∈ [0, 1].
enum PathGenerator {

    /// One sampled point on the path.
    struct Sample {
        let time:      Double
        let position:  SIMD3<Float>   // where the entity is placed
        let axisPoint: SIMD3<Float>   // nearest point on the central axis (same height)
    }

    /// Samples the helix into `count` keyframe points.  `count` is derived from the
    /// total angular travel so denser winds get more samples.
    static func samples(axisStart A: SIMD3<Float>,
                        axisEnd   B: SIMD3<Float>,
                        radius:        Float,
                        startAngleDeg: Float,
                        endAngleDeg:   Float,
                        revolutions:   Float,
                        startTime:     Double,
                        endTime:       Double,
                        keyframesPerRevolution: Float) -> [Sample] {

        let axisVec = B - A
        let len     = simd_length(axisVec)
        // Axis direction; default to world-up for a pure orbit (A == B).
        let d = len > 1e-6 ? axisVec / len : SIMD3<Float>(0, 1, 0)

        // Perpendicular basis with a deterministic 0° reference (world up), with a
        // fallback when the axis is itself near-vertical.
        let worldUp = SIMD3<Float>(0, 1, 0)
        var u = simd_cross(worldUp, d)
        if simd_length(u) < 1e-4 { u = simd_cross(SIMD3<Float>(1, 0, 0), d) }
        u = simd_normalize(u)
        let v = simd_normalize(simd_cross(d, u))

        let dTheta = (endAngleDeg - startAngleDeg) + revolutions * 360.0
        let turns  = abs(dTheta) / 360.0
        let perRev = max(1.0, keyframesPerRevolution)
        let count  = max(2, Int((turns * perRev).rounded(.up)) + 1)

        let deg2rad = Float.pi / 180.0
        var out: [Sample] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let s     = Float(i) / Float(count - 1)
            let theta = (startAngleDeg + s * dTheta) * deg2rad
            let axisP = A + s * axisVec
            let pos   = axisP + radius * (cos(theta) * u + sin(theta) * v)
            let time  = startTime + Double(s) * (endTime - startTime)
            out.append(Sample(time: time, position: pos, axisPoint: axisP))
        }
        return out
    }

    /// Samples a constant-height circle (planar orbit) of `radius` around `center`,
    /// in the plane whose normal is `axisDir` (world-up when `axisDir` is ~zero).
    /// Unlike `samples`, there is no climb along the axis — every `axisPoint` is
    /// `center`, so an orbiting object keeps aiming at the same pivot.  `θ` sweeps
    /// from `startAngleDeg` to `endAngleDeg`; pass a continuous angle run across
    /// segments to keep adjacent rate segments seamless.
    static func planarSamples(center C: SIMD3<Float>,
                              axisDir:       SIMD3<Float>,
                              radius:        Float,
                              startAngleDeg: Float,
                              endAngleDeg:   Float,
                              startTime:     Double,
                              endTime:       Double,
                              count:         Int) -> [Sample] {
        let len = simd_length(axisDir)
        let d   = len > 1e-6 ? axisDir / len : SIMD3<Float>(0, 1, 0)

        let worldUp = SIMD3<Float>(0, 1, 0)
        var u = simd_cross(worldUp, d)
        if simd_length(u) < 1e-4 { u = simd_cross(SIMD3<Float>(1, 0, 0), d) }
        u = simd_normalize(u)
        let v = simd_normalize(simd_cross(d, u))

        let deg2rad = Float.pi / 180.0
        let n = max(2, count)
        var out: [Sample] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let s     = Float(i) / Float(n - 1)
            let theta = (startAngleDeg + s * (endAngleDeg - startAngleDeg)) * deg2rad
            let pos   = C + radius * (cos(theta) * u + sin(theta) * v)
            let time  = startTime + Double(s) * (endTime - startTime)
            out.append(Sample(time: time, position: pos, axisPoint: C))
        }
        return out
    }

    /// Samples a flat spiral arc: the entity sweeps from `start` to `end` around
    /// `target` (the pivot it also aims at), in the plane of the three points, with
    /// the radius easing from |start−target| to |end−target| (so it spirals in/out).
    /// `longArc` picks the long way (>180°) vs the short way around the pivot.
    /// Returns [] if start or end coincides with the target (no radius/angle).
    static func curveSamples(start S: SIMD3<Float>,
                             end   E: SIMD3<Float>,
                             target T: SIMD3<Float>,
                             longArc:   Bool,
                             startTime: Double,
                             endTime:   Double,
                             count:     Int) -> [Sample] {
        let u = S - T, v = E - T
        let rS = simd_length(u), rE = simd_length(v)
        guard rS > 1e-5, rE > 1e-5 else { return [] }
        let uh = u / rS, vh = v / rE

        // Plane normal; fall back to a perpendicular of û when S/E are collinear with T.
        var n = simd_cross(uh, vh)
        if simd_length(n) < 1e-5 {
            var perp = simd_cross(uh, SIMD3<Float>(0, 1, 0))
            if simd_length(perp) < 1e-4 { perp = simd_cross(uh, SIMD3<Float>(1, 0, 0)) }
            n = perp
        }
        n = simd_normalize(n)

        // Short-arc sweep is +θ around n (rotates û onto v̂); the long way goes the
        // other direction, θ − 2π, landing on the same v̂.
        let theta = acos(max(-1, min(1, simd_dot(uh, vh))))
        let sweep = longArc ? (theta - 2 * Float.pi) : theta

        let n2 = max(2, count)
        var out: [Sample] = []
        out.reserveCapacity(n2)
        for i in 0..<n2 {
            let s    = Float(i) / Float(n2 - 1)
            let dir  = simd_quatf(angle: sweep * s, axis: n).act(uh)
            let r    = rS + (rE - rS) * s
            let pos  = T + r * dir
            let time = startTime + Double(s) * (endTime - startTime)
            out.append(Sample(time: time, position: pos, axisPoint: T))
        }
        return out
    }

    /// Samples a straight line from `start` to `end` into `count` (≥2) evenly-spaced
    /// points with matching evenly-spaced times.  Constant velocity — shape accel /
    /// decel via the track's easing mode.
    static func linearSamples(start: SIMD3<Float>,
                              end:   SIMD3<Float>,
                              startTime: Double,
                              endTime:   Double,
                              count:     Int) -> [(time: Double, position: SIMD3<Float>)] {
        let n = max(2, count)
        var out: [(time: Double, position: SIMD3<Float>)] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let s = Float(i) / Float(n - 1)
            let p = start + (end - start) * s
            let t = startTime + Double(s) * (endTime - startTime)
            out.append((t, p))
        }
        return out
    }

    /// Builds a world rotation that aims local −Z at `aim` from `position`, up = world Y.
    /// (Objects have no intrinsic forward; we adopt the −Z convention.)
    static func lookAtRotation(from position: SIMD3<Float>, to aim: SIMD3<Float>) -> simd_quatf {
        let fwd = aim - position
        let len = simd_length(fwd)
        guard len > 1e-6 else { return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }
        let f  = fwd / len                          // desired forward (−Z faces this)
        var up = SIMD3<Float>(0, 1, 0)
        if abs(simd_dot(f, up)) > 0.999 { up = SIMD3<Float>(0, 0, 1) }   // forward ∥ up
        let zCol = -f                               // local +Z points opposite forward
        let xCol = simd_normalize(simd_cross(up, zCol))
        let yCol = simd_cross(zCol, xCol)
        let rotM = matrix_float3x3(columns: (xCol, yCol, zCol))
        return simd_quatf(rotM)
    }

    /// Composes a translation + rotation + (optional) per-axis scale into a 4×4
    /// as T · R · S.  Scale defaults to 1; pass the object's current scale so a
    /// generated path preserves its size instead of resetting it to unit scale.
    static func makeTransform(translation: SIMD3<Float>,
                              rotation: simd_quatf,
                              scale: SIMD3<Float> = SIMD3<Float>(repeating: 1)) -> matrix_float4x4 {
        var m = matrix_float4x4(rotation)
        m.columns.0 *= scale.x
        m.columns.1 *= scale.y
        m.columns.2 *= scale.z
        m.columns.3  = SIMD4<Float>(translation, 1)
        return m
    }

    /// Decomposes an affine 4×4 into translation / rotation / scale, matching the
    /// convention used by ViewportView's keyframe stamping (no shear).
    static func decompose(_ m: matrix_float4x4) -> (translation: SIMD3<Float>,
                                                    rotation: simd_quatf,
                                                    scale: SIMD3<Float>) {
        let translation = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        let c0 = SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z)
        let c1 = SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z)
        let c2 = SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        let sx = simd_length(c0), sy = simd_length(c1), sz = simd_length(c2)
        guard sx > 1e-4, sy > 1e-4, sz > 1e-4 else {
            return (translation, simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), SIMD3<Float>(sx, sy, sz))
        }
        let rotM = matrix_float3x3(columns: (c0 / sx, c1 / sy, c2 / sz))
        return (translation, simd_quatf(rotM), SIMD3<Float>(sx, sy, sz))
    }
}
