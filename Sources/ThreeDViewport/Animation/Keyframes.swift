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

    var keyframes: [TransformKeyframe] = []

    init() {
        print("[DEBUG] KeyframeTrack: initialized, count=0")
    }

    func addKeyframe(_ kf: TransformKeyframe) {
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

            let t = Float((time - a.time) / span)

            let blended = TransformKeyframe(
                time: time,
                translation: Interpolation.lerp(from: a.translation, to: b.translation, t: t),
                rotation:    Interpolation.slerp(from: a.rotation,    to: b.rotation,    t: t),
                scale:       Interpolation.lerp(from: a.scale,       to: b.scale,       t: t)
            )
            return makeMatrix(from: blended)
        }

        return makeMatrix(from: keyframes.last!)
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
