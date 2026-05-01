import simd

// Phase 2 placeholder — typed keyframe tracks for object animation.

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

// Holds an ordered list of keyframes for one SceneObject.
// Phase 2 will add evaluate(at:) using Interpolation helpers.
final class KeyframeTrack {

    var keyframes: [TransformKeyframe] = []

    init() {
        print("[DEBUG] KeyframeTrack: initialized, keyframe count = 0")
    }

    func addKeyframe(_ kf: TransformKeyframe) {
        keyframes.append(kf)
        keyframes.sort { $0.time < $1.time }
        print("[DEBUG] KeyframeTrack: keyframe added at t=" + String(kf.time) + ", total=" + String(keyframes.count))
    }
}
