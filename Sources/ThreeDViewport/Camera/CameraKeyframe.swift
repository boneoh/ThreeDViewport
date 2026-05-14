import simd

// Phase 5: Camera animation keyframe and interpolating track.
//
// Camera keyframes are ABSOLUTE — they store the full camera state at a given
// time (yaw, pitch, distance, target).  Unlike object animation which applies a
// delta on top of baseTransform, the evaluated camera state is applied directly
// to CameraController's properties each frame.

struct CameraKeyframe {
    var time:             Double
    var yaw:              Float
    var pitch:            Float
    var distance:         Float
    var target:           SIMD3<Float>
    /// nil = free camera (default).  non-nil = name of the SceneObject to follow.
    var followTargetName: String? = nil
    /// When followTargetName is set, the offset between the camera yaw and the
    /// "behind yaw" of the followed object at keyframe-creation time.
    /// e.g. 0 = directly behind, π/4 = 45° to the right.
    /// nil = no yaw-relative follow (position-only, absolute yaw).
    var followYawOffset:  Float?  = nil

    init(time: Double, yaw: Float, pitch: Float,
         distance: Float, target: SIMD3<Float>,
         followTargetName: String? = nil,
         followYawOffset:  Float?  = nil) {
        self.time             = time
        self.yaw              = yaw
        self.pitch            = pitch
        self.distance         = distance
        self.target           = target
        self.followTargetName = followTargetName
        self.followYawOffset  = followYawOffset
    }
}

// An ordered list of CameraKeyframes with linear interpolation.
// Yaw uses shortest-path angle lerp so the camera never spins the long way
// around when yaw crosses the ±π boundary.
final class CameraKeyframeTrack {

    var keyframes: [CameraKeyframe] = []

    init() {
        print("[DEBUG] CameraKeyframeTrack: initialized")
    }

    // MARK: - Mutation

    func addKeyframe(_ kf: CameraKeyframe) {
        // Replace any existing keyframe within 1 ms of the same time
        keyframes.removeAll { abs($0.time - kf.time) < 0.001 }
        keyframes.append(kf)
        keyframes.sort { $0.time < $1.time }
        print("[DEBUG] CameraKeyframeTrack: added keyframe at t="
            + String(format: "%.3f", kf.time)
            + " total=" + String(keyframes.count))
    }

    func removeAll() {
        keyframes.removeAll()
        print("[DEBUG] CameraKeyframeTrack: all keyframes removed")
    }

    /// Remove the keyframe at the given index. No-op if index is out of range.
    func removeKeyframe(at index: Int) {
        guard index >= 0, index < keyframes.count else { return }
        let t = keyframes[index].time
        keyframes.remove(at: index)
        print("[DEBUG] CameraKeyframeTrack: removed keyframe at t="
            + String(format: "%.3f", t) + " remaining=" + String(keyframes.count))
    }

    /// Move the keyframe at `index` to `newTime` and re-sort by time.
    func retimeKeyframe(at index: Int, to newTime: Double) {
        guard index >= 0, index < keyframes.count else { return }
        keyframes[index].time = newTime
        keyframes.sort { $0.time < $1.time }
    }

    // MARK: - Evaluation

    /// Returns the interpolated camera state at `time`, or nil if empty.
    func evaluate(at time: Double) -> CameraKeyframe? {
        guard !keyframes.isEmpty else { return nil }

        if time <= keyframes.first!.time { return keyframes.first! }
        if time >= keyframes.last!.time  { return keyframes.last!  }

        for i in 0..<(keyframes.count - 1) {
            let a = keyframes[i]
            let b = keyframes[i + 1]
            guard time >= a.time && time <= b.time else { continue }

            let span = b.time - a.time
            if span < 0.0001 { return b }

            let t = Float((time - a.time) / span)

            return CameraKeyframe(
                time:     time,
                yaw:      lerpAngle(a.yaw,      b.yaw,      t),
                pitch:    lerpFloat(a.pitch,    b.pitch,    t),
                distance: lerpFloat(a.distance, b.distance, t),
                target:   lerpVec3 (a.target,   b.target,   t)
            )
        }
        return keyframes.last!
    }

    // MARK: - Follow camera resolution

    /// Resolves camera-follow overrides at `time`.
    ///
    /// Returns `(target, yaw?)` where:
    ///   • `target` — the world-space position the camera should orbit around.
    ///   • `yaw`    — the camera yaw to apply, or nil to keep the evaluated yaw.
    ///
    /// Returns nil when no follow is active (free → free segment or empty track),
    /// meaning `evaluate(at:)` values are used unchanged.
    ///
    /// `getObjectState` maps an object name to its current world position and
    /// "behind yaw" — the camera yaw that places the camera directly behind the
    /// object.  Passing it as a closure keeps this track decoupled from SceneManager.
    ///
    /// Blending rules (target follows the same logic for yaw when followYawOffset is set):
    ///   free  → free   : nil (no override)
    ///   free  → follow : lerp(a.stored, b.live, alpha)
    ///   follow→ free   : lerp(a.live, b.stored, alpha)
    ///   follow→ follow (same target)     : live continuously
    ///   follow→ follow (different target): snap — use a's target throughout segment
    func resolveFollowCamera(
        at time: Double,
        getObjectState: (String) -> (pos: SIMD3<Float>, behindYaw: Float)?
    ) -> (target: SIMD3<Float>, yaw: Float?)? {

        guard !keyframes.isEmpty else { return nil }

        // ── Before first keyframe ─────────────────────────────────────────────
        if time <= keyframes.first!.time {
            let kf = keyframes.first!
            guard let name = kf.followTargetName,
                  let state = getObjectState(name) else { return nil }
            let yaw = kf.followYawOffset.map { state.behindYaw + $0 }
            return (target: state.pos, yaw: yaw)
        }

        // ── After last keyframe ───────────────────────────────────────────────
        if time >= keyframes.last!.time {
            let kf = keyframes.last!
            guard let name = kf.followTargetName,
                  let state = getObjectState(name) else { return nil }
            let yaw = kf.followYawOffset.map { state.behindYaw + $0 }
            return (target: state.pos, yaw: yaw)
        }

        // ── Between two keyframes ─────────────────────────────────────────────
        for i in 0..<(keyframes.count - 1) {
            let a = keyframes[i]
            let b = keyframes[i + 1]
            guard time >= a.time && time <= b.time else { continue }

            let span  = b.time - a.time
            let alpha = span < 0.0001 ? Float(1) : Float((time - a.time) / span)

            switch (a.followTargetName, b.followTargetName) {

            case (.none, .none):
                return nil   // free → free

            case (.none, .some(let bName)):
                // free → follow: blend stored a.target / a.yaw toward live b values
                guard let bState = getObjectState(bName) else { return nil }
                let blendedTarget = a.target + (bState.pos - a.target) * alpha
                let blendedYaw: Float? = b.followYawOffset.map {
                    lerpAngle(a.yaw, bState.behindYaw + $0, alpha)
                }
                return (target: blendedTarget, yaw: blendedYaw)

            case (.some(let aName), .none):
                // follow → free: blend live a values toward stored b.target / b.yaw
                guard let aState = getObjectState(aName) else {
                    return (target: b.target, yaw: nil)
                }
                let blendedTarget = aState.pos + (b.target - aState.pos) * alpha
                let blendedYaw: Float? = a.followYawOffset.map {
                    lerpAngle(aState.behindYaw + $0, b.yaw, alpha)
                }
                return (target: blendedTarget, yaw: blendedYaw)

            case (.some(let aName), .some(let bName)):
                // follow → follow
                let trackName = (aName == bName) ? aName : aName  // snap: always follow a
                guard let state = getObjectState(trackName) else { return nil }
                let yaw = a.followYawOffset.map { state.behindYaw + $0 }
                return (target: state.pos, yaw: yaw)
            }
        }
        return nil
    }

    // MARK: - Interpolation helpers

    private func lerpFloat(_ a: Float, _ b: Float, _ t: Float) -> Float {
        return a + (b - a) * t
    }

    private func lerpVec3(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
        return a + (b - a) * t
    }

    /// Shortest-path lerp between two angles in radians.
    /// Wraps the delta into [-π, π] so the camera takes the short arc.
    private func lerpAngle(_ a: Float, _ b: Float, _ t: Float) -> Float {
        let twoPi: Float = 2.0 * Float.pi
        var delta = b - a
        while delta >  Float.pi { delta -= twoPi }
        while delta < -Float.pi { delta += twoPi }
        return a + delta * t
    }
}
