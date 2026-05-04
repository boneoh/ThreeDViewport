import simd

// MARK: - LightKeyframe

/// One keyframe for a single light. Stores the properties that can be animated:
/// intensity, colour, direction (normalised; directional/spot/laser), and
/// position (point/spot/laser). Type, cone angles, and enabled state are not
/// animated — change them statically in the Lights & Background inspector.
struct LightKeyframe {
    var time:      Double
    var intensity: Float
    var color:     SIMD3<Float>
    var direction: SIMD3<Float>   // always normalised
    var position:  SIMD3<Float>
}

// MARK: - LightKeyframeTrack

/// Ordered, interpolating keyframe track for one light. All four animated
/// properties are linearly interpolated; direction is re-normalised after lerp
/// to keep it unit-length. API mirrors KeyframeTrack / CameraKeyframeTrack.
final class LightKeyframeTrack {

    var keyframes: [LightKeyframe] = []

    // MARK: - Mutation

    func addKeyframe(_ kf: LightKeyframe) {
        // Replace any existing keyframe within 1 ms of the same time.
        keyframes.removeAll { abs($0.time - kf.time) < 0.001 }
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
                time:      time,
                intensity: a.intensity + (b.intensity - a.intensity) * t,
                color:     a.color     + (b.color     - a.color)     * t,
                direction: simd_length(blendedDir) > 0.0001
                           ? simd_normalize(blendedDir)
                           : a.direction,
                position:  a.position  + (b.position  - a.position)  * t
            )
        }
        return keyframes.last!
    }
}
