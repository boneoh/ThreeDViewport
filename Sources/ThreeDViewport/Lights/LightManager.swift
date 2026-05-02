import simd

// Manages the scene's lights.
// Phase 1: one directional light + ambient.
// Phase 6: keyboard-driven direction and intensity adjustment.
final class LightManager {

    var primaryLight: LightConfig
    var ambientColor: SIMD3<Float>

    // Convenience accessor for shader upload
    var ambientColorVec4: SIMD4<Float> {
        return SIMD4<Float>(ambientColor, 0)
    }

    init() {
        primaryLight = .defaultDirectional
        ambientColor = SIMD3<Float>(0.08, 0.08, 0.12)

        if primaryLight.intensity <= 0 {
            print("[DEBUG] LightManager: primaryLight intensity is zero or negative")
        }
        print("[DEBUG] LightManager: initialized — intensity=" + String(primaryLight.intensity))
    }

    // MARK: - Keyboard control (Phase 6)

    // Rotates the primary light direction:
    //   deltaAzimuth  — rotation around the world Y-axis (positive = counter-clockwise from above)
    //   deltaElevation — tilt toward/away from zenith (positive = tilts light upward/shallower)
    func rotatePrimary(deltaAzimuth: Float, deltaElevation: Float) {
        var dir = primaryLight.direction

        // ── Azimuth: rotate dir around world Y ───────────────────────────────
        if abs(deltaAzimuth) > 0.0001 {
            let c = cos(deltaAzimuth)
            let s = sin(deltaAzimuth)
            let nx = dir.x * c + dir.z * s
            let nz = -dir.x * s + dir.z * c
            dir = SIMD3<Float>(nx, dir.y, nz)
        }

        // ── Elevation: rotate around the axis perpendicular to dir and Y ─────
        if abs(deltaElevation) > 0.0001 {
            // Right vector (perpendicular to dir in the XZ plane and world Y)
            let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), dir))
            let c = cos(deltaElevation)
            let s = sin(deltaElevation)
            // Rodrigues' rotation formula: v' = v*cos + (k×v)*sin + k*(k·v)*(1-cos)
            let dot   = simd_dot(right, dir)
            let cross = simd_cross(right, dir)
            dir = dir * c + cross * s + right * (dot * (1 - c))
        }

        // Guard against degenerate direction (nearly parallel to world Y)
        let xzLen = sqrt(dir.x * dir.x + dir.z * dir.z)
        if xzLen < 0.01 {
            // Nudge back from the pole to avoid gimbal issues
            dir.y = dir.y > 0 ? 0.98 : -0.98
            dir.x = 0.1
        }

        primaryLight.direction = simd_normalize(dir)
        print("[DEBUG] LightManager: direction=("
            + String(format: "%.3f", primaryLight.direction.x) + ","
            + String(format: "%.3f", primaryLight.direction.y) + ","
            + String(format: "%.3f", primaryLight.direction.z) + ")")
    }

    // Adjusts intensity by `delta`, clamped to [0.05, 5.0].
    func adjustIntensity(delta: Float) {
        primaryLight.intensity = max(0.05, min(5.0, primaryLight.intensity + delta))
        print("[DEBUG] LightManager: intensity=" + String(format: "%.2f", primaryLight.intensity))
    }
}
