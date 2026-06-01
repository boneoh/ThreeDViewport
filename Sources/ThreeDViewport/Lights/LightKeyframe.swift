import simd

// MARK: - LightKeyframe

/// One keyframe for a single light. Stores the properties that can be animated:
/// intensity, colour, target (world-space aim point; directional/spot/laser),
/// position (point/spot/laser), range (beam/spot length), and beamThickness
/// (laser only).  Type, cone angles, and enabled state are not animated — change
/// them statically in the Lights & Background inspector.
struct LightKeyframe {
    var time:          Double
    var intensity:     Float
    var color:         SIMD3<Float>
    var target:        SIMD3<Float>   // world-space aim point
    var position:      SIMD3<Float>
    var range:         Float
    var beamThickness: Float
}

// MARK: - LightKeyframeTrack

/// Ordered, interpolating keyframe track for one light. All animated properties
/// (position, target, colour, intensity, range, beamThickness) are linearly
/// interpolated. API mirrors KeyframeTrack / CameraKeyframeTrack.
final class LightKeyframeTrack {

    var keyframes: [LightKeyframe] = []
    /// Per-track interpolation mode (linear or spline tiers).  Default linear.
    var easingMode: EasingMode = .linear

    // MARK: - Mutation

    func addKeyframe(_ kf: LightKeyframe, mergeTolerance: Double = 0.001) {
        // Replace the NEAREST existing keyframe within `mergeTolerance` (see KeyframeTrack).
        if let idx = keyframes.indices
            .filter({ abs(keyframes[$0].time - kf.time) <= mergeTolerance })
            .min(by: { abs(keyframes[$0].time - kf.time) < abs(keyframes[$1].time - kf.time) }) {
            keyframes.remove(at: idx)
        }
        keyframes.append(kf)
        keyframes.sort { $0.time < $1.time }
        print("[DEBUG] LightKeyframeTrack: added keyframe at t="
            + String(format: "%.3f", kf.time)
            + " total=" + String(keyframes.count))
    }

    func removeKeyframe(at index: Int) {
        guard index >= 0, index < keyframes.count else { return }
        let t = keyframes[index].time
        keyframes.remove(at: index)
        print("[DEBUG] LightKeyframeTrack: removed keyframe at t="
            + String(format: "%.3f", t)
            + " remaining=" + String(keyframes.count))
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
        var moving: [LightKeyframe] = []
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
        print("[DEBUG] LightKeyframeTrack: all keyframes removed")
    }

    // MARK: - Evaluation

    /// Returns the linearly interpolated light state at `time`, or nil if empty.
    func evaluate(at time: Double) -> LightKeyframe? {
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
            // matching the object/camera tracks.  Linear → plain lerp.
            if let tension = easingMode.splinePosTension {
                let prev = i > 0 ? keyframes[i - 1] : mirror(b, around: a)
                let next = i + 2 < keyframes.count ? keyframes[i + 2] : mirror(a, around: b)
                func cr(_ p0: Float, _ p1: Float, _ p2: Float, _ p3: Float) -> Float {
                    EasingMode.catmullRomTensioned(p0, p1, p2, p3, t: t, tension: tension)
                }
                func crv(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>, _ p2: SIMD3<Float>, _ p3: SIMD3<Float>) -> SIMD3<Float> {
                    EasingMode.catmullRomTensioned(p0, p1, p2, p3, t: t, tension: tension)
                }
                return LightKeyframe(
                    time:          time,
                    intensity:     cr(prev.intensity, a.intensity, b.intensity, next.intensity),
                    color:         crv(prev.color, a.color, b.color, next.color),
                    target:        crv(prev.target, a.target, b.target, next.target),
                    position:      crv(prev.position, a.position, b.position, next.position),
                    range:         cr(prev.range, a.range, b.range, next.range),
                    beamThickness: cr(prev.beamThickness, a.beamThickness, b.beamThickness, next.beamThickness)
                )
            }

            return LightKeyframe(
                time:          time,
                intensity:     a.intensity     + (b.intensity     - a.intensity)     * t,
                color:         a.color         + (b.color         - a.color)         * t,
                target:        a.target        + (b.target        - a.target)        * t,
                position:      a.position      + (b.position      - a.position)      * t,
                range:         a.range         + (b.range         - a.range)         * t,
                beamThickness: a.beamThickness + (b.beamThickness - a.beamThickness) * t
            )
        }
        return keyframes.last!
    }

    /// Reflects keyframe `k` across `pivot` to synthesise a phantom end neighbour.
    private func mirror(_ k: LightKeyframe, around pivot: LightKeyframe) -> LightKeyframe {
        LightKeyframe(
            time:          2 * pivot.time - k.time,
            intensity:     2 * pivot.intensity - k.intensity,
            color:         2 * pivot.color - k.color,
            target:        2 * pivot.target - k.target,
            position:      2 * pivot.position - k.position,
            range:         2 * pivot.range - k.range,
            beamThickness: 2 * pivot.beamThickness - k.beamThickness)
    }
}
