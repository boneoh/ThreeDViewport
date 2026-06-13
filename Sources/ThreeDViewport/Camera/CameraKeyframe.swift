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
    /// When followTargetName is set, the camera's **forward direction** at
    /// keyframe-creation time, expressed in the followed object's local
    /// frame as a unit vector.  Preferred over `followYawOffset` /
    /// `followPitchOffset` because it correctly preserves the camera-to-head
    /// direction under arbitrary head orientation (yaw + pitch + roll), where
    /// the yaw/pitch-offset approach loses information at gimbal-lock or when
    /// the head rolls.  At playback time `state.basis * followForwardLocal`
    /// is the world-space forward; yaw and pitch are derived from it.
    /// nil = use the legacy yaw/pitch-offset path (older keyframes).
    var followForwardLocal: SIMD3<Float>? = nil
    /// When followTargetName is set, the camera's **up direction** at keyframe-
    /// creation time, expressed in the followed object's local frame as a unit
    /// vector.  At playback `state.basis * followUpLocal` is the world-space up
    /// vector for the view matrix, so the camera rolls with the followed
    /// object (POV / over-the-shoulder shots stay glued to the head's frame).
    /// nil = use world Y up — matches the legacy behaviour of every keyframe
    /// stamped before this field existed.
    var followUpLocal: SIMD3<Float>? = nil

    init(time: Double, yaw: Float, pitch: Float,
         distance: Float, target: SIMD3<Float>,
         fov: Float,
         followTargetName:   String? = nil,
         followYawOffset:    Float?  = nil,
         followPitchOffset:  Float?  = nil,
         targetOffset:       SIMD3<Float> = SIMD3<Float>(0, 0, 0),
         followForwardLocal: SIMD3<Float>? = nil,
         followUpLocal:      SIMD3<Float>? = nil) {
        self.time               = time
        self.yaw                = yaw
        self.pitch              = pitch
        self.distance           = distance
        self.target             = target
        self.fov                = fov
        self.followTargetName   = followTargetName
        self.followYawOffset    = followYawOffset
        self.followPitchOffset  = followPitchOffset
        self.targetOffset       = targetOffset
        self.followForwardLocal = followForwardLocal
        self.followUpLocal      = followUpLocal
    }
}

// An ordered list of CameraKeyframes with linear interpolation.
// Yaw uses shortest-path angle lerp so the camera never spins the long way
// around when yaw crosses the ±π boundary.
final class CameraKeyframeTrack {

    var keyframes: [CameraKeyframe] = []
    /// Per-track interpolation mode (linear or spline tiers).  Default linear so
    /// existing projects animate exactly as before.
    var easingMode: EasingMode = .linear

    init() {
        print("[DEBUG] CameraKeyframeTrack: initialized")
    }

    // MARK: - Mutation

    func addKeyframe(_ kf: CameraKeyframe, mergeTolerance: Double = 0.001) {
        // Replace the NEAREST existing keyframe within `mergeTolerance` (see KeyframeTrack).
        if let idx = keyframes.indices
            .filter({ abs(keyframes[$0].time - kf.time) <= mergeTolerance })
            .min(by: { abs(keyframes[$0].time - kf.time) < abs(keyframes[$1].time - kf.time) }) {
            keyframes.remove(at: idx)
        }
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

    /// Moves keyframes at `fromTimes` to the parallel `toTimes`, overwriting any
    /// other keyframe that lands on a destination time.  See KeyframeTrack.moveKeyframes.
    func moveKeyframes(from fromTimes: [Double], to toTimes: [Double]) {
        guard fromTimes.count == toTimes.count, !fromTimes.isEmpty else { return }
        let tol = 0.0005
        var moving: [CameraKeyframe] = []
        for ft in fromTimes {
            if let kf = keyframes.first(where: { abs($0.time - ft) < tol }) { moving.append(kf) }
        }
        for ft in fromTimes { keyframes.removeAll { abs($0.time - ft) < tol } }
        for (i, kf) in moving.enumerated() {
            var k = kf; k.time = toTimes[i]
            addKeyframe(k)
        }
    }

    // MARK: - Evaluation

    /// Returns the interpolated camera state at `time`, or nil if empty.
    func evaluate(at time: Double, cutoff: Double? = nil) -> CameraKeyframe? {
        guard !keyframes.isEmpty else { return nil }

        // Hold at the last keyframe within `cutoff` (the timeline end) so keyframes
        // left beyond a shortened duration don't pull the in-range animation.
        let endKF = cutoff.flatMap { c in keyframes.last(where: { $0.time <= c + 1e-9 }) }
                    ?? keyframes.last!
        if time <= keyframes.first!.time { return keyframes.first! }
        if time >= endKF.time            { return endKF }

        for i in 0..<(keyframes.count - 1) {
            let a = keyframes[i]
            let b = keyframes[i + 1]
            guard time >= a.time && time <= b.time else { continue }

            let span = b.time - a.time
            if span < 0.0001 { return b }

            let t = Float((time - a.time) / span)

            // Spline easing: Catmull-Rom through the neighbouring keyframes (with
            // end-point mirroring), matching the object tracks.  Linear → plain lerp.
            if let tension = easingMode.splinePosTension {
                let prev = i > 0 ? keyframes[i - 1] : mirror(b, around: a)
                let next = i + 2 < keyframes.count ? keyframes[i + 2] : mirror(a, around: b)
                func cr(_ p0: Float, _ p1: Float, _ p2: Float, _ p3: Float) -> Float {
                    EasingMode.catmullRomTensioned(p0, p1, p2, p3, t: t, tension: tension)
                }
                // Yaw stays shortest-path: unwrap neighbours relative to a.yaw.
                let yPrev = unwrap(prev.yaw, near: a.yaw)
                let yA    = a.yaw
                let yB    = unwrap(b.yaw, near: a.yaw)
                let yNext = unwrap(next.yaw, near: yB)
                return CameraKeyframe(
                    time:     time,
                    yaw:      cr(yPrev, yA, yB, yNext),
                    pitch:    cr(prev.pitch, a.pitch, b.pitch, next.pitch),
                    distance: cr(prev.distance, a.distance, b.distance, next.distance),
                    target:   EasingMode.catmullRomTensioned(prev.target, a.target, b.target, next.target,
                                                             t: t, tension: tension),
                    fov:      cr(prev.fov, a.fov, b.fov, next.fov)
                )
            }

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

    /// Reflects keyframe `k`'s interpolated fields across `pivot` to synthesise a
    /// phantom neighbour at the ends of the track (so Catmull-Rom has 4 points).
    private func mirror(_ k: CameraKeyframe, around pivot: CameraKeyframe) -> CameraKeyframe {
        CameraKeyframe(
            time:     2 * pivot.time - k.time,
            yaw:      2 * pivot.yaw - k.yaw,
            pitch:    2 * pivot.pitch - k.pitch,
            distance: 2 * pivot.distance - k.distance,
            target:   2 * pivot.target - k.target,
            fov:      2 * pivot.fov - k.fov)
    }

    /// Returns `angle` shifted by ±2π so it lies within π of `ref` (shortest path).
    private func unwrap(_ angle: Float, near ref: Float) -> Float {
        let twoPi: Float = 2.0 * Float.pi
        var a = angle
        while a - ref >  Float.pi { a -= twoPi }
        while a - ref < -Float.pi { a += twoPi }
        return a
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
    ) -> (target: SIMD3<Float>, yaw: Float?, pitch: Float?, worldUp: SIMD3<Float>?)? {

        guard !keyframes.isEmpty else { return nil }

        // ── Before first keyframe ─────────────────────────────────────────────
        if time <= keyframes.first!.time {
            let kf = keyframes.first!
            guard let name = kf.followTargetName,
                  let state = getObjectState(name) else { return nil }
            let (yaw, pitch) = resolvedYawPitch(for: kf, state: state)
            let up = kf.followUpLocal.map { state.basis * $0 }
            return (target: state.pos + state.basis * kf.targetOffset,
                    yaw: yaw, pitch: pitch, worldUp: up)
        }

        // ── After last keyframe ───────────────────────────────────────────────
        if time >= keyframes.last!.time {
            let kf = keyframes.last!
            guard let name = kf.followTargetName,
                  let state = getObjectState(name) else { return nil }
            let (yaw, pitch) = resolvedYawPitch(for: kf, state: state)
            let up = kf.followUpLocal.map { state.basis * $0 }
            return (target: state.pos + state.basis * kf.targetOffset,
                    yaw: yaw, pitch: pitch, worldUp: up)
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
                let (bYaw, bPitch) = resolvedYawPitch(for: b, state: bState)
                let blendedYaw:   Float? = bYaw  .map { lerpAngle(a.yaw,   $0, alpha) }
                let blendedPitch: Float? = bPitch.map { lerpFloat(a.pitch, $0, alpha) }
                // Free side has no up — only engage roll once we're past the
                // halfway point of the segment, then snap to b's worldUp.
                let up = (alpha >= 0.5) ? b.followUpLocal.map { bState.basis * $0 } : nil
                return (target: blendedTarget, yaw: blendedYaw, pitch: blendedPitch, worldUp: up)

            case (.some(let aName), .none):
                // follow → free: blend live a values toward stored b.target / b.yaw / b.pitch
                guard let aState = getObjectState(aName) else {
                    return (target: b.target, yaw: nil, pitch: nil, worldUp: nil)
                }
                let aTargetLive = aState.pos + aState.basis * a.targetOffset
                let blendedTarget = aTargetLive + (b.target - aTargetLive) * alpha
                let (aYaw, aPitch) = resolvedYawPitch(for: a, state: aState)
                let blendedYaw:   Float? = aYaw  .map { lerpAngle($0, b.yaw,   alpha) }
                let blendedPitch: Float? = aPitch.map { lerpFloat($0, b.pitch, alpha) }
                // Hold a's worldUp until the halfway point, then release to world-Y.
                let up = (alpha < 0.5) ? a.followUpLocal.map { aState.basis * $0 } : nil
                return (target: blendedTarget, yaw: blendedYaw, pitch: blendedPitch, worldUp: up)

            case (.some(let aName), .some(let bName)):
                // follow → follow
                if aName == bName {
                    // Same target: interpolate everything live, including yaw
                    // and pitch offsets, so the camera transitions smoothly
                    // between the two follow framings without snapping at b.
                    guard let state = getObjectState(aName) else { return nil }
                    let localOffset = a.targetOffset + (b.targetOffset - a.targetOffset) * alpha
                    let (aYaw, aPitch) = resolvedYawPitch(for: a, state: state)
                    let (bYaw, bPitch) = resolvedYawPitch(for: b, state: state)
                    let yaw   = blendOptionalAngle(aYaw, bYaw,   fallbackA: a.yaw,   fallbackB: b.yaw,   alpha: alpha)
                    let pitch = blendOptionalFloat(aPitch, bPitch, fallbackA: a.pitch, fallbackB: b.pitch, alpha: alpha)
                    // Up vector: blend in the object's local frame so the result
                    // rolls with the head smoothly.  A side without followUpLocal is
                    // treated as world-Y (not snapped at the midpoint), so a POV
                    // keyframe next to a non-POV one eases its roll across the whole
                    // segment instead of flipping in a single frame.
                    let up = blendedWorldUp(a.followUpLocal, b.followUpLocal,
                                            basis: state.basis, alpha: alpha)
                    return (target: state.pos + state.basis * localOffset, yaw: yaw, pitch: pitch, worldUp: up)
                } else {
                    // Different target: snap — use a's target throughout segment.
                    guard let state = getObjectState(aName) else { return nil }
                    let (yaw, pitch) = resolvedYawPitch(for: a, state: state)
                    let up = a.followUpLocal.map { state.basis * $0 }
                    return (target: state.pos + state.basis * a.targetOffset, yaw: yaw, pitch: pitch, worldUp: up)
                }
            }
        }
        return nil
    }

    /// Smoothly blends the segment's world-space up vector for the same-target
    /// follow case, avoiding the hard snap at alpha = 0.5 that rolled the frame in
    /// a single tick.  A side without `followUpLocal` is treated as plain world-Y
    /// (expressed in the object's local frame as `basisᵀ · worldY`), so the result
    /// is continuous across the whole segment AND continuous with neighbouring
    /// world-Y segments.  Returns nil only when BOTH sides are world-Y (no roll).
    private func blendedWorldUp(_ aUp: SIMD3<Float>?, _ bUp: SIMD3<Float>?,
                                basis: matrix_float3x3, alpha: Float) -> SIMD3<Float>? {
        guard aUp != nil || bUp != nil else { return nil }
        // World-Y in the object's local frame (basis is orthonormal → transpose = inverse).
        let worldYLocal = basis.transpose * SIMD3<Float>(0, 1, 0)
        let aLocal = aUp ?? worldYLocal
        let bLocal = bUp ?? worldYLocal
        let blended = aLocal + (bLocal - aLocal) * alpha
        let world = basis * blended
        let len = simd_length(world)
        return len > 1e-5 ? world / len : nil
    }

    // MARK: - Per-keyframe yaw/pitch resolution

    /// Resolves the camera's world-space yaw and pitch for a single follow
    /// keyframe at the followed object's current pose.
    ///
    /// Prefers the new `followForwardLocal` field (a unit vector in the
    /// object's local frame): rotate by the object's current basis to get
    /// the world-space forward direction, then derive yaw / pitch from it.
    /// This preserves the camera direction exactly under arbitrary head
    /// rotation (yaw, pitch, roll, combined) — no gimbal-lock issues.
    ///
    /// Falls back to the legacy `followYawOffset` / `followPitchOffset`
    /// fields (offsets from the object's "behind" angles) so keyframes
    /// stamped before `followForwardLocal` was added still resolve.
    private func resolvedYawPitch(
        for kf: CameraKeyframe,
        state: (pos: SIMD3<Float>, behindYaw: Float, behindPitch: Float, basis: matrix_float3x3)
    ) -> (yaw: Float?, pitch: Float?) {
        if let fwdLocal = kf.followForwardLocal {
            // Camera's forward direction in world space, derived by rotating
            // the stored local-frame forward by the object's current basis.
            let fwd = state.basis * fwdLocal
            let len = simd_length(fwd)
            guard len > 0.0001 else {
                // Degenerate stored vector — fall through to the legacy path
                // (if either offset is set) or return nils.
                let yaw   = kf.followYawOffset  .map { state.behindYaw   + $0 }
                let pitch = kf.followPitchOffset.map { state.behindPitch + $0 }
                return (yaw, pitch)
            }
            let n = fwd / len
            // CameraController convention (see CameraController.eyePosition):
            //   forward = -(cos(pitch)·sin(yaw), sin(pitch), cos(pitch)·cos(yaw))
            // Invert to recover yaw / pitch from the forward vector.
            let yaw   = atan2(-n.x, -n.z)
            let pitch = asin(max(-1, min(1, -n.y)))
            return (yaw, pitch)
        }
        let yaw   = kf.followYawOffset  .map { state.behindYaw   + $0 }
        let pitch = kf.followPitchOffset.map { state.behindPitch + $0 }
        return (yaw, pitch)
    }

    /// Interpolates two optional angles for a same-target follow→follow
    /// segment.  When one side has no follow-derived angle, the other side's
    /// stored absolute angle (`fallbackA` / `fallbackB`) is used so blending
    /// stays smooth even across a follow/stored boundary.
    private func blendOptionalAngle(_ aVal: Float?, _ bVal: Float?,
                                    fallbackA: Float, fallbackB: Float,
                                    alpha: Float) -> Float? {
        switch (aVal, bVal) {
        case (.some(let a), .some(let b)): return lerpAngle(a, b, alpha)
        case (.some(let a), .none):        return lerpAngle(a, fallbackB, alpha)
        case (.none, .some(let b)):        return lerpAngle(fallbackA, b, alpha)
        case (.none, .none):               return nil
        }
    }

    /// Linear-blend version of `blendOptionalAngle`, for pitch (clamped to
    /// (-π/2, π/2) so wraparound isn't a concern).
    private func blendOptionalFloat(_ aVal: Float?, _ bVal: Float?,
                                    fallbackA: Float, fallbackB: Float,
                                    alpha: Float) -> Float? {
        switch (aVal, bVal) {
        case (.some(let a), .some(let b)): return lerpFloat(a, b, alpha)
        case (.some(let a), .none):        return lerpFloat(a, fallbackB, alpha)
        case (.none, .some(let b)):        return lerpFloat(fallbackA, b, alpha)
        case (.none, .none):               return nil
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
