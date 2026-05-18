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
    /// Vertical FOV in radians at this keyframe ("focal length" in the UI).
    /// Stored absolutely and linearly interpolated between adjacent keyframes.
    var fov:              Float
    /// nil = free camera (default).  non-nil = name of the SceneObject to follow.
    var followTargetName: String? = nil
    /// When followTargetName is set, the offset between the camera yaw and the
    /// "behind yaw" of the followed object at keyframe-creation time.
    /// e.g. 0 = directly behind, π/4 = 45° to the right.
    /// nil = no yaw-relative follow (position-only, absolute yaw).
    var followYawOffset:  Float?  = nil
    /// When followTargetName is set, the offset between the camera pitch and the
    /// "behind pitch" of the followed object at keyframe-creation time.  Lets
    /// the camera tilt with the head when the head pitches up/down.
    /// nil = no pitch-relative follow (camera pitch from keyframe, absolute).
    /// Absent in keyframes saved before pitch-follow was added.
    var followPitchOffset: Float? = nil
    /// When followTargetName is set, the offset from the followed object's
    /// world-space origin to the actual camera target at keyframe-creation
    /// time, expressed in the followed object's **local frame**.  Stored
    /// locally so that at playback time it rotates with the object — if the
    /// head rotates, the camera target rotates with it, matching the way yaw
    /// and pitch are rebased on the head's current facing.  Lets the camera
    /// orbit a visual centre (e.g. the middle of a head) rather than a joint
    /// origin.
    var targetOffset: SIMD3<Float> = SIMD3<Float>(0, 0, 0)

    init(time: Double, yaw: Float, pitch: Float,
         distance: Float, target: SIMD3<Float>,
         fov: Float,
         followTargetName:  String? = nil,
         followYawOffset:   Float?  = nil,
         followPitchOffset: Float?  = nil,
         targetOffset:      SIMD3<Float> = SIMD3<Float>(0, 0, 0)) {
        self.time              = time
        self.yaw               = yaw
        self.pitch             = pitch
        self.distance          = distance
        self.target            = target
        self.fov               = fov
        self.followTargetName  = followTargetName
        self.followYawOffset   = followYawOffset
        self.followPitchOffset = followPitchOffset
        self.targetOffset      = targetOffset
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
                target:   lerpVec3 (a.target,   b.target,   t),
                fov:      lerpFloat(a.fov,      b.fov,      t)
            )
        }
        return keyframes.last!
    }

    // MARK: - Follow camera resolution

    /// Resolves camera-follow overrides at `time`.
    ///
    /// Returns `(target, yaw?, pitch?)` where:
    ///   • `target` — the world-space position the camera should orbit around.
    ///   • `yaw`    — the camera yaw to apply, or nil to keep the evaluated yaw.
    ///   • `pitch`  — the camera pitch to apply, or nil to keep the evaluated pitch.
    ///                Only non-nil when the keyframe(s) captured a followPitchOffset
    ///                (i.e. were stamped after pitch-follow was added).
    ///
    /// Returns nil when no follow is active (free → free segment or empty track),
    /// meaning `evaluate(at:)` values are used unchanged.
    ///
    /// `getObjectState` maps an object name to its current world position,
    /// "behind yaw" / "behind pitch" (camera yaw and pitch placing the camera
    /// directly behind the object's local +Z axis), and `basis` (the object's
    /// 3×3 world rotation; columns are its local +X/+Y/+Z axes in world
    /// space).  Passing it as a closure keeps this track decoupled from
    /// SceneManager.  `basis` is used to convert each keyframe's stored
    /// local-space `targetOffset` into world space at playback time, so the
    /// target rotates with the object the same way yaw/pitch do.
    ///
    /// Blending rules apply identically to yaw and pitch (when both are present):
    ///   free  → free   : nil (no override)
    ///   free  → follow : lerp(a.stored, b.live, alpha)
    ///   follow→ free   : lerp(a.live, b.stored, alpha)
    ///   follow→ follow (same target)     : lerp(a.live, b.live, alpha)
    ///   follow→ follow (different target): snap — use a's target throughout segment
    func resolveFollowCamera(
        at time: Double,
        getObjectState: (String) -> (pos: SIMD3<Float>, behindYaw: Float, behindPitch: Float, basis: matrix_float3x3)?
    ) -> (target: SIMD3<Float>, yaw: Float?, pitch: Float?)? {

        guard !keyframes.isEmpty else { return nil }

        // ── Before first keyframe ─────────────────────────────────────────────
        if time <= keyframes.first!.time {
            let kf = keyframes.first!
            guard let name = kf.followTargetName,
                  let state = getObjectState(name) else { return nil }
            let yaw   = kf.followYawOffset  .map { state.behindYaw   + $0 }
            let pitch = kf.followPitchOffset.map { state.behindPitch + $0 }
            return (target: state.pos + state.basis * kf.targetOffset, yaw: yaw, pitch: pitch)
        }

        // ── After last keyframe ───────────────────────────────────────────────
        if time >= keyframes.last!.time {
            let kf = keyframes.last!
            guard let name = kf.followTargetName,
                  let state = getObjectState(name) else { return nil }
            let yaw   = kf.followYawOffset  .map { state.behindYaw   + $0 }
            let pitch = kf.followPitchOffset.map { state.behindPitch + $0 }
            return (target: state.pos + state.basis * kf.targetOffset, yaw: yaw, pitch: pitch)
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
                // free → follow: blend stored a.target / a.yaw / a.pitch toward live b values
                guard let bState = getObjectState(bName) else { return nil }
                let bTargetLive = bState.pos + bState.basis * b.targetOffset
                let blendedTarget = a.target + (bTargetLive - a.target) * alpha
                let blendedYaw: Float? = b.followYawOffset.map {
                    lerpAngle(a.yaw, bState.behindYaw + $0, alpha)
                }
                let blendedPitch: Float? = b.followPitchOffset.map {
                    lerpFloat(a.pitch, bState.behindPitch + $0, alpha)
                }
                return (target: blendedTarget, yaw: blendedYaw, pitch: blendedPitch)

            case (.some(let aName), .none):
                // follow → free: blend live a values toward stored b.target / b.yaw / b.pitch
                guard let aState = getObjectState(aName) else {
                    return (target: b.target, yaw: nil, pitch: nil)
                }
                let aTargetLive = aState.pos + aState.basis * a.targetOffset
                let blendedTarget = aTargetLive + (b.target - aTargetLive) * alpha
                let blendedYaw: Float? = a.followYawOffset.map {
                    lerpAngle(aState.behindYaw + $0, b.yaw, alpha)
                }
                let blendedPitch: Float? = a.followPitchOffset.map {
                    lerpFloat(aState.behindPitch + $0, b.pitch, alpha)
                }
                return (target: blendedTarget, yaw: blendedYaw, pitch: blendedPitch)

            case (.some(let aName), .some(let bName)):
                // follow → follow
                if aName == bName {
                    // Same target: interpolate everything live, including yaw
                    // and pitch offsets, so the camera transitions smoothly
                    // between the two follow framings without snapping at b.
                    guard let state = getObjectState(aName) else { return nil }
                    let localOffset = a.targetOffset + (b.targetOffset - a.targetOffset) * alpha
                    let yaw = resolveFollowYaw(
                        a: a, b: b,
                        liveBehindYaw: state.behindYaw,
                        alpha: alpha)
                    let pitch = resolveFollowPitch(
                        a: a, b: b,
                        liveBehindPitch: state.behindPitch,
                        alpha: alpha)
                    return (target: state.pos + state.basis * localOffset, yaw: yaw, pitch: pitch)
                } else {
                    // Different target: snap — use a's target throughout segment.
                    guard let state = getObjectState(aName) else { return nil }
                    let yaw   = a.followYawOffset  .map { state.behindYaw   + $0 }
                    let pitch = a.followPitchOffset.map { state.behindPitch + $0 }
                    return (target: state.pos + state.basis * a.targetOffset, yaw: yaw, pitch: pitch)
                }
            }
        }
        return nil
    }

    /// Interpolates the camera yaw across a same-target follow→follow segment.
    /// Handles the four combinations of yaw-offset presence on a and b, so
    /// segments where one side has only an absolute yaw still blend smoothly.
    private func resolveFollowYaw(a: CameraKeyframe, b: CameraKeyframe,
                                  liveBehindYaw: Float, alpha: Float) -> Float? {
        switch (a.followYawOffset, b.followYawOffset) {
        case (.some(let aOff), .some(let bOff)):
            return lerpAngle(liveBehindYaw + aOff, liveBehindYaw + bOff, alpha)
        case (.some(let aOff), .none):
            return lerpAngle(liveBehindYaw + aOff, b.yaw, alpha)
        case (.none, .some(let bOff)):
            return lerpAngle(a.yaw, liveBehindYaw + bOff, alpha)
        case (.none, .none):
            return nil
        }
    }

    /// Interpolates the camera pitch across a same-target follow→follow segment.
    /// Mirrors `resolveFollowYaw` but with linear (non-angular) interpolation
    /// because pitch is clamped to (-π/2, π/2) and never wraps.
    private func resolveFollowPitch(a: CameraKeyframe, b: CameraKeyframe,
                                    liveBehindPitch: Float, alpha: Float) -> Float? {
        switch (a.followPitchOffset, b.followPitchOffset) {
        case (.some(let aOff), .some(let bOff)):
            return lerpFloat(liveBehindPitch + aOff, liveBehindPitch + bOff, alpha)
        case (.some(let aOff), .none):
            return lerpFloat(liveBehindPitch + aOff, b.pitch, alpha)
        case (.none, .some(let bOff)):
            return lerpFloat(a.pitch, liveBehindPitch + bOff, alpha)
        case (.none, .none):
            return nil
        }
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
