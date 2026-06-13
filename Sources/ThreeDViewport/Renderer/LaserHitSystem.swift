import simd

// CPU-side laser hit detection and spark particle simulation.
// Pure Swift — no Metal dependency.
// Phase 9: laser hit effect (star flare + sparks).
//
// Hit detection uses a ray-OBB test:
//   1. Transform the ray from world space into the object's local space using
//      the inverse of the object's transform matrix.
//   2. Run a standard ray-AABB slab test against the local-space bounding box.
//   3. Transform the local hit point back to world space.
//
// This gives correct per-axis tightness for any object shape — a flat plane,
// a long thin rod, a complex mesh — without needing triangle-level intersection.
//
// Usage per frame:
//   updateHits(lights:objects:groupTransforms:)   — detect hits
//   updateParticles(dt:)          — advance / emit particles
//   buildSparkGPUData()           — produce [SparkParticleGPU] for the GPU

final class LaserHitSystem {

    // MARK: - Hit info

    struct HitInfo {
        var point:     SIMD3<Float>   // world-space position on the surface
        var direction: SIMD3<Float>   // normalised beam direction at the hit
        var color:     SIMD3<Float>   // laser RGB colour
        var distance:  Float          // world-space distance from laser origin to hit
    }

    /// Keyed by light-slot index; repopulated each frame by updateHits.
    private(set) var hits: [Int: HitInfo] = [:]

    // MARK: - Particle simulation

    private struct Particle {
        var position: SIMD3<Float>
        var velocity: SIMD3<Float>
        var color:    SIMD3<Float>
        var life:     Float   // seconds remaining
        var maxLife:  Float   // used to compute normalised alpha
    }

    private var particles:        [Particle]   = []
    private let maxParticles:     Int          = 256
    private var emitAccumulators: [Int: Float] = [:]   // per-light-slot

    // MARK: - Public API

    /// Tests every active laser against all visible objects and stores results in `hits`.
    func updateHits(lights: [LightConfig], objects: [SceneObject],
                    groupTransforms: [Int: matrix_float4x4]) {
        hits.removeAll(keepingCapacity: true)
        for (i, laser) in lights.enumerated() {
            guard laser.type == .laser, laser.isEnabled else { continue }
            let origin = laser.position
            let dir    = simd_normalize(laser.direction)
            if let (hitPoint, hitDist) = nearestHit(origin:    origin,
                                                    direction: dir,
                                                    objects:   objects,
                                                    groupTransforms: groupTransforms,
                                                    maxRange:  laser.range) {
                hits[i] = HitInfo(point:     hitPoint,
                                  direction: dir,
                                  color:     laser.color,
                                  distance:  hitDist)
            }
        }
    }

    /// Advances the particle simulation by `dt` seconds and emits new sparks for each hit.
    func updateParticles(dt: Float) {
        let gravity: Float = 2.5
        let drag:    Float = 3.0

        // Age, move, and prune existing particles
        particles = particles.compactMap { p in
            var q = p
            q.life -= dt
            guard q.life > 0 else { return nil }
            q.velocity.y -= gravity * dt
            q.velocity   *= max(0, 1.0 - drag * dt)
            q.position   += q.velocity * dt
            return q
        }

        // Emit new sparks at each live hit
        for (lightIdx, hit) in hits {
            var acc = emitAccumulators[lightIdx, default: 0]
            acc += 30.0 * dt   // 30 sparks / second
            let toEmit = Int(acc)
            acc -= Float(toEmit)
            emitAccumulators[lightIdx] = acc

            for _ in 0..<toEmit {
                guard particles.count < maxParticles else { break }
                particles.append(makeParticle(at: hit.point,
                                              along: hit.direction,
                                              color: hit.color))
            }
        }

        // Drop accumulators for lights that are no longer hitting anything
        emitAccumulators = emitAccumulators.filter { hits[$0.key] != nil }
    }

    /// Converts live particles to an array of GPU-ready structs for instanced rendering.
    func buildSparkGPUData() -> [SparkParticleGPU] {
        return particles.map { p in
            let alpha = (p.life / p.maxLife) * (p.life / p.maxLife)   // quadratic fade
            return SparkParticleGPU(
                position: SIMD4<Float>(p.position, 1),
                color:    SIMD4<Float>(p.color,    1),
                size:     0.008 + 0.012 * alpha,
                alpha:    alpha,
                pad:      .zero
            )
        }
    }

    // MARK: - Ray-OBB intersection

    /// Returns (worldHitPoint, worldDistance) for the nearest hit within `maxRange`, or nil.
    ///
    /// Algorithm: transform the ray into each object's local space, run a ray-AABB
    /// slab test against the local bounding box, then reconstruct the world-space
    /// hit point.  This makes the test as tight as the object's actual bounding box
    /// regardless of rotation or non-uniform scale.
    private func nearestHit(origin:    SIMD3<Float>,
                             direction: SIMD3<Float>,
                             objects:   [SceneObject],
                             groupTransforms: [Int: matrix_float4x4],
                             maxRange:  Float) -> (SIMD3<Float>, Float)? {

        var bestDistSq: Float         = maxRange * maxRange
        var bestPoint:  SIMD3<Float>? = nil
        var bestDist:   Float         = 0

        // An object stops the laser if it visually occludes it: either it's drawn
        // (isVisible), or it's a depth-only holdout (occludeWhenHidden) — but NOT a
        // transparent holdout (glass), which is excluded from holdout occlusion so
        // the beam passes through it, matching the rendered depth.  This makes hit
        // detection agree with the beam's depth-clipping in every export pass,
        // including FX Solo/Matte where all geometry is held out.
        for obj in objects where obj.isVisible
            || (obj.occludeWhenHidden
                && !(obj.material.opacity < 1.0 || obj.material.baseColorFactor.w < 1.0)) {
            // Full world transform must match how the object is RENDERED: grouped
            // parts draw as groupTransforms[gid] * obj.transform, so a moved/rotated
            // multi-part model would otherwise be hit-tested at its un-grouped origin
            // and the beam would pass straight through it.
            let world      = obj.groupID.flatMap { groupTransforms[$0] }
                                .map { $0 * obj.transform } ?? obj.transform

            // Transform the world-space ray into this object's local space.
            // simd_inverse handles arbitrary transforms (rotation, scale, translation).
            let inv        = simd_inverse(world)
            let lo4        = inv * SIMD4<Float>(origin,    1)
            let ld4        = inv * SIMD4<Float>(direction, 0)
            let localO     = SIMD3<Float>(lo4.x, lo4.y, lo4.z)
            let localD     = SIMD3<Float>(ld4.x, ld4.y, ld4.z)

            // Slab test against the local AABB
            guard let localT = rayAABB(origin:    localO,
                                        direction: localD,
                                        boxMin:    obj.boundingMin,
                                        boxMax:    obj.boundingMax) else { continue }

            // Reconstruct world-space hit point and measure distance from laser origin
            let localHit   = localO + localD * localT
            let worldHit4  = world * SIMD4<Float>(localHit, 1)
            let worldHit   = SIMD3<Float>(worldHit4.x, worldHit4.y, worldHit4.z)
            let distSq     = simd_length_squared(worldHit - origin)

            guard distSq < bestDistSq else { continue }
            bestDistSq = distSq
            bestDist   = sqrt(distSq)
            bestPoint  = worldHit
        }

        if let p = bestPoint { return (p, bestDist) }
        return nil
    }

    /// Standard slab ray-AABB test.  Returns the entry t (local-space parameter)
    /// for the nearest forward intersection, or nil on miss / behind-ray hit.
    ///
    /// IEEE 754 behaviour when direction[i] == 0 is handled naturally:
    /// 1/0 = ±inf, and the slab tests collapse correctly for parallel rays.
    private func rayAABB(origin:    SIMD3<Float>,
                          direction: SIMD3<Float>,
                          boxMin:    SIMD3<Float>,
                          boxMax:    SIMD3<Float>) -> Float? {
        var tNear: Float = -.infinity
        var tFar:  Float =  .infinity

        for i in 0..<3 {
            let invD = 1.0 / direction[i]
            var t0   = (boxMin[i] - origin[i]) * invD
            var t1   = (boxMax[i] - origin[i]) * invD
            if t0 > t1 { let tmp = t0; t0 = t1; t1 = tmp }
            tNear = max(tNear, t0)
            tFar  = min(tFar, t1)
            if tNear > tFar { return nil }   // ray misses the slab
        }

        if tFar  < 0    { return nil }     // box entirely behind ray origin
        return tNear >= 0 ? tNear : tFar   // entry point (or exit if inside box)
    }

    // MARK: - Particle factory

    /// Creates a spark flying away from `point` perpendicular to `beamDir`.
    private func makeParticle(at point: SIMD3<Float>,
                               along beamDir: SIMD3<Float>,
                               color: SIMD3<Float>) -> Particle {
        // Perpendicular frame from beam direction
        let ref:   SIMD3<Float> = abs(beamDir.y) < 0.9
                                ? SIMD3<Float>(0, 1, 0)
                                : SIMD3<Float>(1, 0, 0)
        let right = simd_normalize(simd_cross(beamDir, ref))
        let up2   = simd_cross(beamDir, right)

        let angle   = Float.random(in: 0 ..< .pi * 2)
        let lateral = Float.random(in: 0.0 ..< 1.0)
        let back    = Float.random(in: 0.0 ..< 0.3)
        let speed   = Float.random(in: 0.4 ..< 2.0)

        let lateralDir = right * cos(angle) + up2 * sin(angle)
        let vel = simd_normalize(lateralDir * lateral - beamDir * back) * speed

        let life = Float.random(in: 0.3 ..< 0.8)
        return Particle(position: point, velocity: vel,
                        color: color, life: life, maxLife: life)
    }
}
