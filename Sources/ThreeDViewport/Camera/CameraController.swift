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

    // Phase 5: optional camera animation track.
    // When set, the renderer evaluates it each frame and writes directly to
    // yaw / pitch / distance / target.  Manual orbit is preserved when paused.
    var keyframeTrack: CameraKeyframeTrack?

    var fovYRadians: Float = 27.0 * Float.pi / 180.0   // 27° ≈ 50mm full-frame equivalent
    let nearPlane: Float   = 0.01
    let farPlane: Float    = 2000.0

    /// When true, the renderer (and exporter) skip `applyCameraFollow` and leave
    /// `target` / `yaw` alone.  Used during edit mode for a camera-follow keyframe
    /// so the user's adjustments to position and aim aren't immediately overwritten
    /// by the follow-resolved values each frame.
    var followSuspended: Bool = false

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

    /// Inverse of `eyePosition`: re-derive yaw / pitch / distance so the camera
    /// eye sits at `eye`, keeping `target` fixed.  Distance and pitch are clamped
    /// to the same limits as zoom / orbit so the camera stays well-conditioned.
    /// Used by the Camera inspector's editable Position field.
    func setEyePosition(_ eye: SIMD3<Float>) {
        var d    = eye - target
        var dist = simd_length(d)
        if dist < 1e-4 {
            // Eye coincides with target (e.g. clicking "Z" on Position when target
            // is at the origin) — push target away along world −Z by the current
            // orbit distance so the back-solve is well-defined.  Net effect: the
            // eye lands where asked and the camera ends up looking along −Z.
            let fallback: Float = distance > 1e-4 ? distance : 5.0
            target = eye + SIMD3<Float>(0, 0, -fallback)
            d      = eye - target                  // = (0, 0, fallback)
            dist   = fallback
        }
        distance = min(5000.0, max(0.05, dist))
        var p    = asin(max(-1, min(1, d.y / dist)))
        p        = max(-Float.pi / 2 + 0.01, min(Float.pi / 2 - 0.01, p))
        pitch    = p
        yaw      = atan2(d.x, d.z)
    }

    /// Sets the look-at `target` while keeping the eye where it currently sits —
    /// re-aims the camera instead of translating the whole orbit rig.  Used by the
    /// Camera inspector's Target sliders so editing Target doesn't drag Position.
    func setTargetKeepingEye(_ newTarget: SIMD3<Float>) {
        let savedEye = eyePosition
        target = newTarget
        setEyePosition(savedEye)               // back-solve yaw / pitch / distance
    }

    /// Unit vector pointing from the camera toward the target (world space).
    var forwardVector: SIMD3<Float> {
        simd_normalize(target - eyePosition)
    }

    /// Camera's right vector in world space (perpendicular to forward and world-up).
    var rightVector: SIMD3<Float> {
        simd_normalize(simd_cross(forwardVector, SIMD3<Float>(0, 1, 0)))
    }

    /// Camera's up vector in world space (perpendicular to right and forward).
    var upVector: SIMD3<Float> {
        simd_cross(rightVector, forwardVector)
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

    /// Dolly: slide both eye and target along the current forward direction so the
    /// camera physically moves through the scene.  Unlike lens zoom (which changes FOV),
    /// dolly physically repositions the camera.
    /// Step size is proportional to max(distance, 1.0) so it never freezes at small radii.
    func dolly(delta: Float) {
        let sensitivity: Float = 0.05
        let step = delta * sensitivity * max(distance, 1.0)
        target += forwardVector * step
    }

    /// Lens zoom: change the field of view to simulate a zoom lens.
    /// Scroll up (positive delta) narrows the FOV (zoom in); scroll down widens it (zoom out).
    /// Clamped to 10°–90° to avoid unusable extremes.
    func lensZoom(delta: Float) {
        let sensitivity: Float = 0.02   // radians per scroll unit
        fovYRadians -= delta * sensitivity
        let minFOV = Float.pi / 18.0    // 10°
        let maxFOV = Float.pi / 2.0     // 90°
        fovYRadians = max(minFOV, min(maxFOV, fovYRadians))
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

    /// Free-look: camera position stays fixed; aim direction rotates.
    /// Analogous to rotating an object in place — only the orientation changes.
    /// After adjusting yaw/pitch, target is repositioned so eyePosition is unchanged.
    func freeLook(deltaYaw: Float, deltaPitch: Float) {
        let eye = eyePosition                       // save current position
        yaw   -= deltaYaw
        pitch  = max(-Float.pi / 2.0 + 0.01,
                 min( Float.pi / 2.0 - 0.01, pitch - deltaPitch))
        // Push target out along the new forward direction, keeping eye fixed.
        let cosP   = cos(pitch)
        let offset = SIMD3<Float>(cosP * sin(yaw), sin(pitch), cosP * cos(yaw))
        target = eye - distance * offset
    }

    // MARK: - Convenience

    func reset() {
        yaw         = 0
        pitch       = 0.4
        distance    = 5.0
        target      = SIMD3<Float>(0, 0, 0)
        fovYRadians = 27.0 * Float.pi / 180.0
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
