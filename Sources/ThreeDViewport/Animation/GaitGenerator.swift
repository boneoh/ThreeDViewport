import simd
import Foundation

/// Builds the keyframes for a gait: the root (whole-model) following a smooth path
/// through the chosen marks at a set speed + facing direction of travel, and the limb
/// joints cycling in step with distance traveled.  Pure data in → keyframes out; the
/// caller writes them onto the group track + per-part tracks.
struct GaitGenerator {

    struct Output {
        var rootKeys: [TransformKeyframe]               // → group keyframe track
        var limbKeys: [String: [TransformKeyframe]]     // partName → per-part track
        var endTime:  Double
        var missingJoints: [String]
    }

    /// - marks:        path waypoints in order (world space), ≥ 2.
    /// - speed:        world units / second (> 0).
    /// - strideLength: distance covered by one full gait cycle (both feet step once).
    /// - groupScale:   keep the model's current scale on the root keyframes.
    /// - availableJoints: part names present in the target model (for missing-joint report).
    static func generate(gait: GaitType,
                         params: GaitParams,
                         marks: [SIMD3<Float>],
                         speed: Float,
                         strideLength: Float,
                         startTime: Double,
                         groundOffset: Float,
                         groupScale: SIMD3<Float>,
                         availableJoints: Set<String>) -> Output {

        let spline = CatmullRom(points: marks)
        let total  = spline.length
        guard total > 1e-4, speed > 1e-4, strideLength > 1e-4 else {
            return Output(rootKeys: [], limbKeys: [:], endTime: startTime, missingJoints: [])
        }

        // Sample density: ~10 keys per stride, with a floor so short paths still cycle.
        let cycles  = total / strideLength
        let count   = max(2, Int((cycles * 10).rounded(.up)) + 1)
        let endTime = startTime + Double(total / speed)

        var rootKeys: [TransformKeyframe] = []
        var limbKeys: [String: [TransformKeyframe]] = [:]

        let required = GaitCycle.requiredJoints(for: gait)
        let present  = required.filter { availableJoints.contains($0) }
        let missing  = required.filter { !availableJoints.contains($0) }
        for j in present { limbKeys[j] = [] }

        let identityQ = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        let prone     = GaitCycle.bodyOrientation(gait)   // identity for non-swim
        // Ease INTO the gait from standing at the first mark, and back to standing at
        // the last, over a fixed TIME window at each end (capped to half the gait so a
        // short path still reaches a real middle).  `rest` = 1 at the ends → 0 mid-gait.
        let totalTime:     Float = total / speed
        let transitionDur: Float = min(1.0, totalTime * 0.5)   // seconds, each end
        func smoothstep(_ x: Float) -> Float { let c = max(0, min(1, x)); return c * c * (3 - 2 * c) }

        // Turning lean: bank the body into curves ∝ speed²·curvature (a runner leaning
        // into a corner).  Tunable; flip leanGain's sign if it banks the wrong way.
        let leanGain: Float = -0.07
        let maxLean:  Float = 25 * .pi / 180
        let leanEps:  Float = max(0.02, total * 0.02)
        func yawAt(_ d: Float) -> Float {
            let t = spline.tangent(atDistance: min(max(d, 0), total)); return atan2(t.x, t.z)
        }

        for k in 0..<count {
            let f    = Float(k) / Float(count - 1)
            let dist = f * total
            let time = startTime + Double(dist / speed)
            let pos  = spline.point(atDistance: dist)
            let tan  = spline.tangent(atDistance: dist)
            let phase = (dist / strideLength).truncatingRemainder(dividingBy: 1)

            // Stand→walk at the start and walk→stand at the end.
            let elapsed   = dist / speed                  // seconds since the first mark
            let remaining = (total - dist) / speed        // seconds to the last mark
            let easeIn = (transitionDur > 1e-4 && elapsed   < transitionDur)
                         ? smoothstep((transitionDur - elapsed)   / transitionDur) : 0
            let settle = (transitionDur > 1e-4 && remaining < transitionDur)
                         ? smoothstep((transitionDur - remaining) / transitionDur) : 0
            let rest = max(easeIn, settle)                // 1 = standing rest, 0 = full gait

            // Root: heading (yaw so +Z faces travel) composed with body orientation.
            // Swim swims prone with its center at the mark (yOffset 0) and stands at BOTH
            // ends (body → upright, yOffset → groundOffset); upright gaits keep feet on
            // the ground throughout.  The bob fades at the ends so the body stands level.
            let yaw      = atan2(tan.x, tan.z)
            let heading  = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
            let body     = simd_slerp(prone, identityQ, rest)     // prone=identity for non-swim
            // Bank into the turn: roll about the travel axis (+Z), faded at the ends.
            var leanQ = identityQ
            if gait != .swim {
                var dYaw = yawAt(dist + leanEps) - yawAt(dist - leanEps)
                while dYaw >  .pi { dYaw -= 2 * .pi }
                while dYaw < -.pi { dYaw += 2 * .pi }
                let kappa = dYaw / (2 * leanEps)                  // signed curvature, rad/unit
                let lean  = max(-maxLean, min(maxLean, leanGain * speed * speed * kappa)) * (1 - rest)
                leanQ = simd_quatf(angle: lean, axis: SIMD3<Float>(0, 0, 1))
            }
            let rotation = heading * leanQ * body
            let yOffset  = (gait == .swim) ? groundOffset * rest : groundOffset
            let y        = pos.y + yOffset + GaitCycle.bob(gait, phase: phase, params) * (1 - rest)
            let bobbed   = SIMD3<Float>(pos.x, y, pos.z)
            rootKeys.append(TransformKeyframe(time: time, translation: bobbed,
                                              rotation: rotation, scale: groupScale))

            // Limbs: local joint rotations, eased from/to the rest pose at the ends.
            let pose = GaitCycle.pose(gait, phase: phase, params)
            for j in present {
                var q = pose[j] ?? identityQ
                if rest > 0 { q = simd_slerp(q, identityQ, rest) }
                limbKeys[j]?.append(TransformKeyframe(time: time, translation: .zero,
                                                      rotation: q, scale: SIMD3<Float>(1, 1, 1)))
            }
        }

        return Output(rootKeys: rootKeys, limbKeys: limbKeys,
                      endTime: endTime, missingJoints: missing)
    }
}

/// Minimal uniform Catmull-Rom spline through a list of points, with an arc-length
/// table for constant-speed sampling.  Endpoints are duplicated so the curve passes
/// through the first and last marks.
private struct CatmullRom {
    private let pts: [SIMD3<Float>]
    private let arc: [(d: Float, t: Float)]   // cumulative distance → global param t
    let length: Float

    init(points: [SIMD3<Float>]) {
        // Need ≥2; pad ends for tangents.
        if points.count >= 2 {
            pts = [points.first!] + points + [points.last!]
        } else {
            pts = points + points + points   // degenerate (caller guards length)
        }
        // Build arc-length table by densely walking the curve.
        let segs = max(1, (points.count - 1))
        let stepsPerSeg = 32
        var table: [(Float, Float)] = []
        var acc: Float = 0
        var prev = CatmullRom.eval(pts, t: 0)
        table.append((0, 0))
        let totalSteps = segs * stepsPerSeg
        for i in 1...totalSteps {
            let t = Float(i) / Float(totalSteps) * Float(segs)
            let p = CatmullRom.eval(pts, t: t)
            acc += simd_length(p - prev)
            table.append((acc, t))
            prev = p
        }
        arc = table
        length = acc
    }

    /// Global param `t` (0…segments) at a given arc-length distance.
    private func param(atDistance d: Float) -> Float {
        guard d > 0 else { return 0 }
        guard d < length else { return arc.last!.t }
        // Binary search the cumulative table.
        var lo = 0, hi = arc.count - 1
        while lo + 1 < hi {
            let mid = (lo + hi) / 2
            if arc[mid].d < d { lo = mid } else { hi = mid }
        }
        let (d0, t0) = arc[lo], (d1, t1) = arc[hi]
        let u = (d1 - d0) > 1e-6 ? (d - d0) / (d1 - d0) : 0
        return t0 + u * (t1 - t0)
    }

    func point(atDistance d: Float) -> SIMD3<Float> { CatmullRom.eval(pts, t: param(atDistance: d)) }

    func tangent(atDistance d: Float) -> SIMD3<Float> {
        let t  = param(atDistance: d)
        let e: Float = 0.01
        let a  = CatmullRom.eval(pts, t: max(0, t - e))
        let b  = CatmullRom.eval(pts, t: min(Float(pts.count - 3), t + e))
        let v  = b - a
        let len = simd_length(v)
        return len > 1e-6 ? v / len : SIMD3<Float>(0, 0, 1)
    }

    /// Evaluate the padded control points at global param t (0 = first real point).
    private static func eval(_ p: [SIMD3<Float>], t: Float) -> SIMD3<Float> {
        let maxSeg = p.count - 3                      // number of real segments
        let tc  = min(max(t, 0), Float(maxSeg))
        let i   = min(Int(tc), maxSeg - 1)            // segment index
        let lt  = tc - Float(i)
        let p0 = p[i], p1 = p[i + 1], p2 = p[i + 2], p3 = p[i + 3]
        let t2 = lt * lt
        let t3 = t2 * lt
        // Uniform Catmull-Rom basis, summed in steps so the type-checker keeps up.
        let a: SIMD3<Float> = 2 * p1
        let b: SIMD3<Float> = (p2 - p0) * lt
        let c: SIMD3<Float> = (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2
        let d: SIMD3<Float> = (3 * p1 - 3 * p2 + p3 - p0) * t3
        return 0.5 * (a + b + c + d)
    }
}
