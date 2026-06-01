import simd

// MARK: - AtmosphereKeyframe

/// One keyframe for an atmosphere effect (fog volume or particle emitter).  Fog
/// and particles animate the same property set, so they share this type.  The
/// master Enabled toggle and the particle Type are NOT animated — change them
/// statically in the Atmosphere panel (to fade an effect in, animate `density`).
struct AtmosphereKeyframe {
    var time:     Double
    var position: SIMD3<Float>
    var size:     SIMD3<Float>
    var density:  Float
    var variance: Float
    var color:    SIMD3<Float>
}

// MARK: - AtmosphereKeyframeTrack

/// Ordered, linearly-interpolating keyframe track for one atmosphere effect.
/// API mirrors LightKeyframeTrack (add / remove / retime / move / evaluate).
final class AtmosphereKeyframeTrack {

    var keyframes: [AtmosphereKeyframe] = []
    /// Per-track interpolation mode (linear or spline tiers).  Default linear.
    var easingMode: EasingMode = .linear

    // MARK: - Mutation

    func addKeyframe(_ kf: AtmosphereKeyframe, mergeTolerance: Double = 0.001) {
        // Replace the NEAREST existing keyframe within `mergeTolerance` (see KeyframeTrack).
        if let idx = keyframes.indices
            .filter({ abs(keyframes[$0].time - kf.time) <= mergeTolerance })
            .min(by: { abs(keyframes[$0].time - kf.time) < abs(keyframes[$1].time - kf.time) }) {
            keyframes.remove(at: idx)
        }
        keyframes.append(kf)
        keyframes.sort { $0.time < $1.time }
        print("[DEBUG] AtmosphereKeyframeTrack: added keyframe at t="
            + String(format: "%.3f", kf.time) + " total=" + String(keyframes.count))
    }

    func removeKeyframe(at index: Int) {
        guard index >= 0, index < keyframes.count else { return }
        let t = keyframes[index].time
        keyframes.remove(at: index)
        print("[DEBUG] AtmosphereKeyframeTrack: removed keyframe at t="
            + String(format: "%.3f", t) + " remaining=" + String(keyframes.count))
    }

    func retimeKeyframe(at index: Int, to newTime: Double) {
        guard index >= 0, index < keyframes.count else { return }
        keyframes[index].time = newTime
        keyframes.sort { $0.time < $1.time }
    }

    /// Moves keyframes at `fromTimes` to the parallel `toTimes`, overwriting any
    /// other keyframe that lands on a destination time.  See KeyframeTrack.moveKeyframes.
    func moveKeyframes(from fromTimes: [Double], to toTimes: [Double]) {
        guard fromTimes.count == toTimes.count, !fromTimes.isEmpty else { return }
        let tol = 0.0005
        var moving: [AtmosphereKeyframe] = []
        for ft in fromTimes {
            if let kf = keyframes.first(where: { abs($0.time - ft) < tol }) { moving.append(kf) }
        }
        for ft in fromTimes { keyframes.removeAll { abs($0.time - ft) < tol } }
        for (i, kf) in moving.enumerated() {
            var k = kf; k.time = toTimes[i]
            addKeyframe(k)
        }
    }

    func removeAll() {
        keyframes.removeAll()
        print("[DEBUG] AtmosphereKeyframeTrack: all keyframes removed")
    }

    // MARK: - Evaluation

    /// Returns the linearly interpolated state at `time`, or nil if empty.
    func evaluate(at time: Double) -> AtmosphereKeyframe? {
        guard !keyframes.isEmpty else { return nil }

        if time <= keyframes.first!.time { return keyframes.first! }
        if time >= keyframes.last!.time  { return keyframes.last!  }

        for i in 0..<(keyframes.count - 1) {
            let a = keyframes[i], b = keyframes[i + 1]
            guard time >= a.time && time <= b.time else { continue }

            let span = b.time - a.time
            if span < 0.0001 { return b }

            let t = Float((time - a.time) / span)

            // Spline easing: Catmull-Rom through neighbours (end-point mirrored),
            // matching the object/camera/light tracks.  Linear → plain lerp.
            if let tension = easingMode.splinePosTension {
                let prev = i > 0 ? keyframes[i - 1] : mirror(b, around: a)
                let next = i + 2 < keyframes.count ? keyframes[i + 2] : mirror(a, around: b)
                func cr(_ p0: Float, _ p1: Float, _ p2: Float, _ p3: Float) -> Float {
                    EasingMode.catmullRomTensioned(p0, p1, p2, p3, t: t, tension: tension)
                }
                func crv(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>, _ p2: SIMD3<Float>, _ p3: SIMD3<Float>) -> SIMD3<Float> {
                    EasingMode.catmullRomTensioned(p0, p1, p2, p3, t: t, tension: tension)
                }
                return AtmosphereKeyframe(
                    time:     time,
                    position: crv(prev.position, a.position, b.position, next.position),
                    size:     crv(prev.size, a.size, b.size, next.size),
                    density:  cr(prev.density, a.density, b.density, next.density),
                    variance: cr(prev.variance, a.variance, b.variance, next.variance),
                    color:    crv(prev.color, a.color, b.color, next.color)
                )
            }

            return AtmosphereKeyframe(
                time:     time,
                position: a.position + (b.position - a.position) * t,
                size:     a.size     + (b.size     - a.size)     * t,
                density:  a.density  + (b.density  - a.density)  * t,
                variance: a.variance + (b.variance - a.variance) * t,
                color:    a.color    + (b.color    - a.color)    * t
            )
        }
        return keyframes.last!
    }

    /// Reflects keyframe `k` across `pivot` to synthesise a phantom end neighbour.
    private func mirror(_ k: AtmosphereKeyframe, around pivot: AtmosphereKeyframe) -> AtmosphereKeyframe {
        AtmosphereKeyframe(
            time:     2 * pivot.time - k.time,
            position: 2 * pivot.position - k.position,
            size:     2 * pivot.size - k.size,
            density:  2 * pivot.density - k.density,
            variance: 2 * pivot.variance - k.variance,
            color:    2 * pivot.color - k.color)
    }
}
