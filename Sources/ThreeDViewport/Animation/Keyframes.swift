import simd

// One keyframe in a transform track.
struct TransformKeyframe {
    var time: Double
    var translation: SIMD3<Float>
    var rotation: simd_quatf
    var scale: SIMD3<Float>

    init(time: Double,
         translation: SIMD3<Float> = SIMD3<Float>(0, 0, 0),
         rotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
         scale: SIMD3<Float> = SIMD3<Float>(1, 1, 1)) {
        self.time        = time
        self.translation = translation
        self.rotation    = rotation
        self.scale       = scale
    }
}

// An ordered list of keyframes for one SceneObject.
// evaluate(at:) returns the interpolated 4x4 transform matrix at any time.
// The matrix returned is a LOCAL animation delta; multiply by SceneObject.baseTransform
// in the renderer to get the final world transform.
final class KeyframeTrack {

    var keyframes:  [TransformKeyframe] = []
    var easingMode: EasingMode          = .linear

    init() {
        print("[DEBUG] KeyframeTrack: initialized, count=0")
    }

    func addKeyframe(_ kf: TransformKeyframe) {
        // Replace any existing keyframe within 1 ms of the same time (matches CameraKeyframeTrack)
        keyframes.removeAll { abs($0.time - kf.time) < 0.001 }
        keyframes.append(kf)
        keyframes.sort { $0.time < $1.time }
        print("[DEBUG] KeyframeTrack: added keyframe at t=" + String(format: "%.3f", kf.time)
            + " total=" + String(keyframes.count))
    }

    func removeAll() {
        keyframes.removeAll()
        print("[DEBUG] KeyframeTrack: all keyframes removed")
    }

    /// Remove the keyframe at the given index. No-op if index is out of range.
    func removeKeyframe(at index: Int) {
        guard index >= 0, index < keyframes.count else { return }
        let t = keyframes[index].time
        keyframes.remove(at: index)
        print("[DEBUG] KeyframeTrack: removed keyframe at t="
            + String(format: "%.3f", t) + " remaining=" + String(keyframes.count))
    }

    /// Move the keyframe at `index` to `newTime` and re-sort by time.
    func retimeKeyframe(at index: Int, to newTime: Double) {
        guard index >= 0, index < keyframes.count else { return }
        keyframes[index].time = newTime
        keyframes.sort { $0.time < $1.time }
    }

    /// Moves the keyframes currently at `fromTimes` to the parallel `toTimes`,
    /// overwriting any *other* keyframe that lands on a destination time.  The
    /// moving keyframes are pulled out first, so they never overwrite each other
    /// (relative order is preserved regardless of move direction) and re-adding
    /// uses addKeyframe's 1-ms dedupe to remove collision victims.
    func moveKeyframes(from fromTimes: [Double], to toTimes: [Double]) {
        guard fromTimes.count == toTimes.count, !fromTimes.isEmpty else { return }
        let tol = 0.0005
        var moving: [TransformKeyframe] = []
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

    // Returns the interpolated matrix at the given time, or nil if no keyframes.
    func evaluate(at time: Double) -> matrix_float4x4? {
        if keyframes.isEmpty {
            print("[DEBUG] KeyframeTrack: evaluate called but keyframes array is empty")
            return nil
        }

        // Clamp to first / last keyframe
        if time <= keyframes.first!.time { return makeMatrix(from: keyframes.first!) }
        if time >= keyframes.last!.time  { return makeMatrix(from: keyframes.last!)  }

        // Find surrounding pair
        for i in 0..<(keyframes.count - 1) {
            let a = keyframes[i]
            let b = keyframes[i + 1]
            guard time >= a.time && time <= b.time else { continue }

            let span = b.time - a.time
            if span < 0.0001 { return makeMatrix(from: b) }

            let rawT = Float((time - a.time) / span)

            switch easingMode {

            case .linear:
                return makeMatrix(from: TransformKeyframe(
                    time:        time,
                    translation: Interpolation.lerp(from:  a.translation, to: b.translation, t: rawT),
                    rotation:    Interpolation.slerp(from: a.rotation,    to: b.rotation,    t: rawT),
                    scale:       Interpolation.lerp(from:  a.scale,       to: b.scale,       t: rawT)
                ))

            case .splineS, .splineM, .splineL:
                // Tension values: position uses Hermite tangent scale,
                // rotation uses squad inner-point scale.
                //   S → subtle arc  (pos τ=0.25, rot τ=0.5)
                //   M → medium arc  (pos τ=0.50, rot τ=1.0)  ← same math as .smooth
                //   L → wide arc    (pos τ=1.00, rot τ=2.0)
                let posTension: Float
                let rotTension: Float
                switch easingMode {
                case .splineS: posTension = 0.25; rotTension = 0.5
                case .splineM: posTension = 0.5;  rotTension = 1.0
                default:       posTension = 1.0;  rotTension = 2.0  // .splineL
                }

                let prev = i > 0
                    ? keyframes[i - 1]
                    : mirrorKeyframe(b, around: a)
                let next = i + 2 < keyframes.count
                    ? keyframes[i + 2]
                    : mirrorKeyframe(a, around: b)

                let translation = EasingMode.catmullRomTensioned(
                    prev.translation, a.translation, b.translation, next.translation,
                    t: rawT, tension: posTension)
                let scale = EasingMode.catmullRomTensioned(
                    prev.scale, a.scale, b.scale, next.scale,
                    t: rawT, tension: posTension)
                let rotation = EasingMode.squadTensioned(
                    prev.rotation, a.rotation, b.rotation, next.rotation,
                    t: rawT, tension: rotTension)

                return makeMatrix(from: TransformKeyframe(
                    time:        time,
                    translation: translation,
                    rotation:    rotation,
                    scale:       scale
                ))

            case .smooth:
                // Catmull-Rom: virtual control points at endpoints mirror the
                // first real segment so the curve has natural (zero-acceleration)
                // boundary conditions rather than a sharp crease.
                let prev = i > 0
                    ? keyframes[i - 1]
                    : mirrorKeyframe(b, around: a)
                let next = i + 2 < keyframes.count
                    ? keyframes[i + 2]
                    : mirrorKeyframe(a, around: b)

                let translation = EasingMode.catmullRom(
                    prev.translation, a.translation, b.translation, next.translation, t: rawT)
                let scale = EasingMode.catmullRom(
                    prev.scale, a.scale, b.scale, next.scale, t: rawT)
                // simd_spline performs spherical cubic spline interpolation on the
                // unit quaternion sphere — the quaternion equivalent of Catmull-Rom.
                let rotation = simd_spline(prev.rotation, a.rotation, b.rotation, next.rotation, rawT)

                return makeMatrix(from: TransformKeyframe(
                    time:        time,
                    translation: translation,
                    rotation:    rotation,
                    scale:       scale
                ))
            }
        }

        return makeMatrix(from: keyframes.last!)
    }

    // MARK: - Catmull-Rom endpoint helper

    // Creates a virtual control point by mirroring kf2 through kf1.
    // Used to generate a smooth boundary tangent when kf1 is the first or last
    // real keyframe (so there is no actual neighbour on one side).
    private func mirrorKeyframe(_ kf2: TransformKeyframe,
                                 around kf1: TransformKeyframe) -> TransformKeyframe {
        TransformKeyframe(
            time:        kf1.time - (kf2.time - kf1.time),
            translation: 2.0 * kf1.translation - kf2.translation,
            rotation:    simd_slerp(kf2.rotation, kf1.rotation, 2.0),
            scale:       2.0 * kf1.scale - kf2.scale
        )
    }

    // MARK: - Matrix construction

    // T * R * S from a keyframe.
    private func makeMatrix(from kf: TransformKeyframe) -> matrix_float4x4 {
        // Translation
        var T = matrix_identity_float4x4
        T.columns.3 = SIMD4<Float>(kf.translation.x, kf.translation.y, kf.translation.z, 1)

        // Rotation — convert quaternion to 4x4 via the Shepperd algorithm
        // (avoids relying on an uncertain simd_matrix4x4(quatf) bridge).
        let R = rotationMatrix(kf.rotation)

        // Scale
        var S = matrix_identity_float4x4
        S.columns.0.x = kf.scale.x
        S.columns.1.y = kf.scale.y
        S.columns.2.z = kf.scale.z

        return T * R * S
    }

    // Converts a unit quaternion to a column-major 4x4 rotation matrix.
    private func rotationMatrix(_ q: simd_quatf) -> matrix_float4x4 {
        let n = simd_normalize(q)
        let x = n.imag.x, y = n.imag.y, z = n.imag.z, w = n.real
        return matrix_float4x4(columns: (
            SIMD4<Float>(1 - 2*(y*y + z*z),     2*(x*y + z*w),     2*(x*z - y*w), 0),
            SIMD4<Float>(    2*(x*y - z*w), 1 - 2*(x*x + z*z),     2*(y*z + x*w), 0),
            SIMD4<Float>(    2*(x*z + y*w),     2*(y*z - x*w), 1 - 2*(x*x + y*y), 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }
}
