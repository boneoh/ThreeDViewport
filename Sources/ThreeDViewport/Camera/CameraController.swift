import simd

// Orbit camera with pan and zoom.
// Phase 2 will add keyframe animation support via CameraKeyframe.
final class CameraController {

    // Spherical coordinates around `target`
    var yaw: Float   = 0.0
    var pitch: Float = 0.4    // ~23° above horizon
    var distance: Float = 5.0

    // Look-at target in world space
    var target: SIMD3<Float> = SIMD3<Float>(0, 0, 0)

    // Updated by the renderer when the drawable size changes
    var aspectRatio: Float = 16.0 / 9.0

    let fovYRadians: Float = Float.pi / 3.0   // 60°
    let nearPlane: Float   = 0.01
    let farPlane: Float    = 2000.0

    init() {
        print("[DEBUG] CameraController: initialized, distance=" + String(distance))
    }

    // MARK: - Computed properties

    var eyePosition: SIMD3<Float> {
        let x = target.x + distance * cos(pitch) * sin(yaw)
        let y = target.y + distance * sin(pitch)
        let z = target.z + distance * cos(pitch) * cos(yaw)
        return SIMD3<Float>(x, y, z)
    }

    var viewMatrix: matrix_float4x4 {
        return makeLookAt(eye: eyePosition, center: target, up: SIMD3<Float>(0, 1, 0))
    }

    var projectionMatrix: matrix_float4x4 {
        return makePerspective(fovY: fovYRadians, aspect: aspectRatio, near: nearPlane, far: farPlane)
    }

    var viewProjectionMatrix: matrix_float4x4 {
        return projectionMatrix * viewMatrix
    }

    // MARK: - Input handlers

    func orbit(deltaX: Float, deltaY: Float) {
        let sensitivity: Float = 0.005
        yaw   -= deltaX * sensitivity
        pitch += deltaY * sensitivity
        // Clamp pitch to avoid gimbal lock at poles
        pitch = max(-Float.pi / 2.0 + 0.01, min(Float.pi / 2.0 - 0.01, pitch))
    }

    func zoom(delta: Float) {
        let sensitivity: Float = 0.05
        distance -= delta * sensitivity
        distance = max(0.05, min(5000.0, distance))
    }

    // Pan in the plane perpendicular to the view direction
    func pan(deltaX: Float, deltaY: Float) {
        let sensitivity: Float = 0.001
        let eye     = eyePosition
        let forward = simd_normalize(target - eye)
        let right   = simd_normalize(simd_cross(forward, SIMD3<Float>(0, 1, 0)))
        let up      = simd_cross(right, forward)
        target -= right * (deltaX * sensitivity * distance)
        target += up    * (deltaY * sensitivity * distance)
    }

    // MARK: - Convenience

    func reset() {
        yaw      = 0
        pitch    = 0.4
        distance = 5.0
        target   = SIMD3<Float>(0, 0, 0)
        print("[DEBUG] CameraController: reset to defaults")
    }

    // Fit orbit distance so the bounding sphere fills the view
    func fitToScene(boundingRadius: Float, center: SIMD3<Float>) {
        if boundingRadius <= 0 {
            print("[DEBUG] CameraController: fitToScene — boundingRadius is zero or negative, using 1.0")
        }
        let r = max(boundingRadius, 0.001)
        target   = center
        distance = r * 2.5
        pitch    = 0.4
        yaw      = 0
        print("[DEBUG] CameraController: fitToScene radius=" + String(r) + " distance=" + String(distance))
    }

    // MARK: - Math helpers

    private func makeLookAt(eye: SIMD3<Float>,
                             center: SIMD3<Float>,
                             up: SIMD3<Float>) -> matrix_float4x4 {
        let f = simd_normalize(center - eye)
        let r = simd_normalize(simd_cross(f, up))
        let u = simd_cross(r, f)
        return matrix_float4x4(columns: (
            SIMD4<Float>( r.x,  u.x, -f.x, 0),
            SIMD4<Float>( r.y,  u.y, -f.y, 0),
            SIMD4<Float>( r.z,  u.z, -f.z, 0),
            SIMD4<Float>(-simd_dot(r, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)
        ))
    }

    private func makePerspective(fovY: Float,
                                  aspect: Float,
                                  near: Float,
                                  far: Float) -> matrix_float4x4 {
        let ys = 1.0 / tan(fovY * 0.5)
        let xs = ys / aspect
        let zs = far / (near - far)
        return matrix_float4x4(columns: (
            SIMD4<Float>(xs,  0,  0,  0),
            SIMD4<Float>( 0, ys,  0,  0),
            SIMD4<Float>( 0,  0, zs, -1),
            SIMD4<Float>( 0,  0, near * zs, 0)
        ))
    }
}
