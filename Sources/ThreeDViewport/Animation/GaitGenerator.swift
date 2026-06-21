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
        var spedUpSegments: Int = 0                     // timed mode: segments too short for the pace
    }

    /// Geometry for foot-IK (group-local units): leg-segment lengths and the rest hip
    /// positions of each leg.  Present → solve the legs by planting feet; nil → the legs
    /// swing open-loop.
    struct LegRig {
        var thigh: Float                 // |hip → knee|
        var shin:  Float                 // |knee → foot/ankle|
        var hipL:  SIMD3<Float>          // upper_leg_L rest position
        var hipR:  SIMD3<Float>          // upper_leg_R rest position
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
                         legRig: LegRig? = nil,
                         markTimes: [Double]? = nil,   // timed mode: hit mark[i] at markTimes[i]
                         availableJoints: Set<String>) -> Output {

        let spline = CatmullRom(points: marks)
        let total  = spline.length
        guard total > 1e-4, speed > 1e-4, strideLength > 1e-4 else {
            return Output(rootKeys: [], limbKeys: [:], endTime: startTime, missingJoints: [])
        }

        var rootKeys: [TransformKeyframe] = []
        var limbKeys: [String: [TransformKeyframe]] = [:]

        let required = GaitCycle.requiredJoints(for: gait)
        let present  = required.filter { availableJoints.contains($0) }
        let missing  = required.filter { !availableJoints.contains($0) }
        for j in present { limbKeys[j] = [] }

        let identityQ = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        let prone     = GaitCycle.bodyOrientation(gait)   // identity for non-swim
        func smoothstep(_ x: Float) -> Float { let c = max(0, min(1, x)); return c * c * (3 - 2 * c) }

        // ── Build the timed sample list ────────────────────────────────────────────
        // Each sample: where on the path (`dist`), when (`time`), how "standing"
        // (`rest` 1=stand…0=full gait), and local `segSpeed` (drives the turn-lean term).
        // `rest`=1 at the ends and through any dwell → 0 while moving, so the legs cycle
        // only when the body actually travels.
        struct Sample { var dist: Float; var time: Double; var rest: Float; var segSpeed: Float }
        var samples: [Sample] = []
        var spedUp = 0
        let densityPerStride: Float = 10

        if let times = markTimes, times.count == marks.count, marks.count >= 2 {
            // TIMED mode: arrive at mark[i] at times[i].  pace = walk speed; leftover time
            // is a dwell (stand) before departing; if a segment is too short for the pace,
            // speed that segment up so it still arrives on time.
            let md = spline.markDistances
            let n  = marks.count
            var dwell    = [Float](repeating: 0, count: n)         // stand time before leaving mark i
            var segSpeed = [Float](repeating: speed, count: n - 1)
            for i in 0..<(n - 1) {
                let segDist = max(0, md[i + 1] - md[i])
                let gap     = Float(max(0, times[i + 1] - times[i]))
                if gap < 1e-4 { segSpeed[i] = max(speed, segDist / 1e-3); continue }   // ~instant
                let travelAtPace = segDist / speed
                if travelAtPace <= gap { segSpeed[i] = speed;          dwell[i] = gap - travelAtPace }
                else                   { segSpeed[i] = segDist / gap;  spedUp += 1 }   // too short → speed up
            }
            func push(_ d: Float, _ t: Double, _ r: Float, _ sp: Float) {
                samples.append(Sample(dist: d, time: t, rest: r, segSpeed: sp))
            }
            // Stand at the first mark (through its leading dwell).
            push(md[0], times[0], 1, speed)
            if dwell[0] > 1e-3 { push(md[0], times[0] + Double(dwell[0]), 1, speed) }
            for i in 0..<(n - 1) {
                let departT = times[i] + Double(dwell[i])
                let arriveT = times[i + 1]
                let move    = arriveT - departT
                let segDist = max(0, md[i + 1] - md[i])
                let cnt     = max(2, Int((segDist / strideLength * densityPerStride).rounded(.up)) + 1)
                let einOn   = dwell[i] > 1e-3 || i == 0                 // departing a stand
                let eoutOn  = dwell[i + 1] > 1e-3 || i + 1 == n - 1     // arriving into a stand
                let tw      = Float(min(0.6, move * 0.5))
                for k in 1...max(1, cnt - 1) {                          // k=0 already placed
                    let f = Float(k) / Float(cnt - 1)
                    let d = md[i] + f * segDist
                    let t = departT + move * Double(f)
                    let elapsed = Float(t - departT), remaining = Float(arriveT - t)
                    let ein  = (einOn  && tw > 1e-4 && elapsed   < tw) ? smoothstep((tw - elapsed)   / tw) : 0
                    let eout = (eoutOn && tw > 1e-4 && remaining < tw) ? smoothstep((tw - remaining) / tw) : 0
                    push(d, t, max(ein, eout), segSpeed[i])
                }
                if dwell[i + 1] > 1e-3 { push(md[i + 1], arriveT + Double(dwell[i + 1]), 1, speed) }
            }
            if let last = samples.last, last.rest < 1 { push(last.dist, last.time, 1, speed) }
        } else {
            // CONSTANT-SPEED mode (unchanged): uniform samples + global ease in/out.
            let cycles = total / strideLength
            let count  = max(2, Int((cycles * densityPerStride).rounded(.up)) + 1)
            let totalTime:     Float = total / speed
            let transitionDur: Float = min(1.0, totalTime * 0.5)
            for k in 0..<count {
                let f    = Float(k) / Float(count - 1)
                let dist = f * total
                let time = startTime + Double(dist / speed)
                let elapsed = dist / speed, remaining = (total - dist) / speed
                let easeIn = (transitionDur > 1e-4 && elapsed   < transitionDur) ? smoothstep((transitionDur - elapsed)   / transitionDur) : 0
                let settle = (transitionDur > 1e-4 && remaining < transitionDur) ? smoothstep((transitionDur - remaining) / transitionDur) : 0
                samples.append(Sample(dist: dist, time: time, rest: max(easeIn, settle), segSpeed: speed))
            }
        }
        let endTime = samples.last?.time ?? startTime

        // Turning lean: bank the body into curves ∝ speed²·curvature (a runner leaning
        // into a corner).  Tunable; flip leanGain's sign if it banks the wrong way.
        let leanGain: Float = -0.07
        let maxLean:  Float = 25 * .pi / 180
        let leanEps:  Float = max(0.02, total * 0.02)
        func yawAt(_ d: Float) -> Float {
            let t = spline.tangent(atDistance: min(max(d, 0), total)); return atan2(t.x, t.z)
        }

        // ── Foot-IK setup ──────────────────────────────────────────────────────────
        // Each foot is planted at a fixed ground point through its stance, then arcs
        // forward to the next plant during swing — the body rolls over the planted foot
        // (no skating).  `duty` = fraction of the cycle a foot is planted; `rOffset` =
        // the right leg's phase shift (½ cycle = alternating; 0 = both together, for hop).
        let footIK = (legRig != nil && gait != .swim)
        let duty:    Float
        let rOffset: Float
        switch gait {
        case .run: duty = 0.40; rOffset = 0.5     // brief flight phase
        case .hop: duty = 0.45; rOffset = 0.0     // both feet together
        default:   duty = 0.62; rOffset = 0.5     // walk
        }
        let stepLift: Float = (legRig?.thigh ?? 0) * 0.45   // swing-foot lift, group-local

        // World ground point where leg `offset`'s stance number `n` is planted, laterally
        // offset by that leg's hip X so the foot lands under the hip.
        func footfall(_ n: Float, offset: Float, hipX: Float) -> SIMD3<Float> {
            let s  = min(max((n + offset + duty * 0.5) * strideLength, 0), total)
            let p  = spline.point(atDistance: s)
            let tg = spline.tangent(atDistance: s)
            let perp = SIMD3<Float>(tg.z, 0, -tg.x)         // world "right" ≈ model local +X
            return SIMD3<Float>(p.x, p.y, p.z) + perp * (hipX * groupScale.x)
        }

        // Analytic 2-bone IK in the leg's sagittal plane → (hip, knee) rotations about X,
        // matching the rig's rest pose (foot straight down = both angles 0).  `tz`,`ty`
        // are the foot target relative to the hip in group-local space.
        func solve2Bone(a: Float, b: Float, tz: Float, ty: Float) -> (hip: Float, knee: Float) {
            let qz = -tz, qy = -ty                          // measure from +Y (rest = down)
            var d = (qz * qz + qy * qy).squareRoot()
            d = max(abs(a - b) + 1e-3, min(a + b - 1e-3, d))
            let gamma = atan2(qz, qy)
            let cosB  = max(-1, min(1, (a * a + d * d - b * b) / (2 * a * d)))
            let beta  = acos(cosB)
            let phi   = gamma - beta                         // hip from down axis
            let kz = a * sin(phi), ky = a * cos(phi)         // knee point
            let psi = atan2(d * sin(gamma) - kz, d * cos(gamma) - ky)   // shin from down
            return (phi, psi - phi)
        }

        for sample in samples {
            let dist = sample.dist
            let time = sample.time
            let rest = sample.rest                         // 1 = standing rest, 0 = full gait
            let segSpeed = sample.segSpeed                 // local speed for the turn-lean
            let pos  = spline.point(atDistance: dist)
            let tan  = spline.tangent(atDistance: dist)
            let phase = (dist / strideLength).truncatingRemainder(dividingBy: 1)

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
                let lean  = max(-maxLean, min(maxLean, leanGain * segSpeed * segSpeed * kappa)) * (1 - rest)
                leanQ = simd_quatf(angle: lean, axis: SIMD3<Float>(0, 0, 1))
            }
            let rotation = heading * leanQ * body
            let yOffset  = (gait == .swim) ? groundOffset * rest : groundOffset
            let y        = pos.y + yOffset + GaitCycle.bob(gait, phase: phase, params) * (1 - rest)
            let bobbed   = SIMD3<Float>(pos.x, y, pos.z)
            rootKeys.append(TransformKeyframe(time: time, translation: bobbed,
                                              rotation: rotation, scale: groupScale))

            // Foot-IK: solve each leg so its planted foot stays on the ground point and
            // the body rolls over it.  Overrides the open-loop hip/knee for both legs.
            var legAngles: [String: Float] = [:]
            if footIK, let rig = legRig {
                let mRoot = PathGenerator.makeTransform(translation: bobbed,
                                                        rotation: rotation, scale: groupScale)
                func legIK(offset: Float, hip: SIMD3<Float>) -> (Float, Float) {
                    let legPhase = dist / strideLength - offset
                    let n  = floor(legPhase)
                    let fp = legPhase - n
                    var target: SIMD3<Float>
                    if fp < duty {                                  // stance: foot planted
                        target = footfall(n, offset: offset, hipX: hip.x)
                    } else {                                        // swing: arc to next plant
                        let u = (fp - duty) / (1 - duty)
                        let a3 = footfall(n,     offset: offset, hipX: hip.x)
                        let b3 = footfall(n + 1, offset: offset, hipX: hip.x)
                        let s  = smoothstep(u)
                        target = a3 * (1 - s) + b3 * s
                        target.y += stepLift * groupScale.y * sin(.pi * u)
                    }
                    // hip world → foot target relative to hip, back into group-local space.
                    let hw  = mRoot * SIMD4<Float>(hip, 1)
                    let rel = rotation.inverse.act(target - SIMD3<Float>(hw.x, hw.y, hw.z))
                    let lz  = rel.z / groupScale.z, ly = rel.y / groupScale.y
                    return solve2Bone(a: rig.thigh, b: rig.shin, tz: lz, ty: ly)
                }
                let (hL, kL) = legIK(offset: 0,       hip: rig.hipL)
                let (hR, kR) = legIK(offset: rOffset, hip: rig.hipR)
                legAngles = ["upper_leg_L": hL, "knee_L": kL,
                             "upper_leg_R": hR, "knee_R": kR]
            }

            // Limbs: local joint rotations, eased from/to the rest pose at the ends.
            let pose = GaitCycle.pose(gait, phase: phase, params)
            for j in present {
                var q = legAngles[j].map { simd_quatf(angle: $0, axis: SIMD3<Float>(1, 0, 0)) }
                        ?? (pose[j] ?? identityQ)
                if rest > 0 { q = simd_slerp(q, identityQ, rest) }
                limbKeys[j]?.append(TransformKeyframe(time: time, translation: .zero,
                                                      rotation: q, scale: SIMD3<Float>(1, 1, 1)))
            }
        }

        return Output(rootKeys: rootKeys, limbKeys: limbKeys,
                      endTime: endTime, missingJoints: missing, spedUpSegments: spedUp)
    }
}

/// Minimal uniform Catmull-Rom spline through a list of points, with an arc-length
/// table for constant-speed sampling.  Endpoints are duplicated so the curve passes
/// through the first and last marks.
private struct CatmullRom {
    private let pts: [SIMD3<Float>]
    private let arc: [(d: Float, t: Float)]   // cumulative distance → global param t
    let length: Float
    let markDistances: [Float]                 // cumulative arc length at each input mark

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
        // Cumulative arc length at each original mark: integer param t=i sits at table
        // index i*stepsPerSeg (param t = step / stepsPerSeg).
        var mds: [Float] = []
        for i in 0...segs { mds.append(table[min(i * stepsPerSeg, table.count - 1)].0) }
        markDistances = mds
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
