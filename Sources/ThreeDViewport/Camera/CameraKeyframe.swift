import simd

// Phase 4 placeholder — camera animation keyframe.
// Will store yaw/pitch/distance/target at a given timeline time.
struct CameraKeyframe {
    var time: Double          // seconds
    var yaw: Float
    var pitch: Float
    var distance: Float
    var target: SIMD3<Float>

    init(time: Double, yaw: Float, pitch: Float, distance: Float, target: SIMD3<Float>) {
        self.time     = time
        self.yaw      = yaw
        self.pitch    = pitch
        self.distance = distance
        self.target   = target
    }
}
