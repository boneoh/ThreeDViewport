import simd

// MARK: - LightKeyframe

/// One keyframe for a single light. Stores the properties that can be animated:
/// intensity, colour, direction (normalised; directional/spot/laser), position
/// (point/spot/laser), range (beam/spot length), and beamThickness (laser only).
/// Type, cone angles, and enabled state are not animated — change them statically
/// in the Lights & Background inspector.
struct LightKeyframe {
    var time:          Double
    var intensity:     Float
    var color:         SIMD3<Float>
    var direction:     SIMD3<Float>   // always normalised
    var position:      SIMD3<Float>
    var range:         Float
    var beamThickness: Float
}

// MARK: - LightKeyframeTrack

/// Ordered, interpolating keyframe track for one light. All four animated
/// properties are linearly interpolated; direction is re-normalised after lerp
/// to keep it unit-length. API mirrors KeyframeTrack / CameraKeyframeTrack.
final class LightKeyframeTrack {

    var keyframes: [LightKeyframe] = []

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

            let blendedDir = a.direction + (b.direction - a.direction) * t
            return LightKeyframe(
                time:          time,
                intensity:     a.intensity     + (b.intensity     - a.intensity)     * t,
                color:         a.color         + (b.color         - a.color)         * t,
                direction:     simd_length(blendedDir) > 0.0001
                               ? simd_normalize(blendedDir)
                               : a.direction,
                position:      a.position      + (b.position      - a.position)      * t,
                range:         a.range         + (b.range         - a.range)         * t,
                beamThickness: a.beamThickness + (b.beamThickness - a.beamThickness) * t
            )
        }
        return keyframes.last!
    }
}
