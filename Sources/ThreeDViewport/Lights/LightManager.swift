import Combine
import simd

// Phase 7: Manages up to 4 simultaneous lights of any type.
// Conforms to ObservableObject so the SwiftUI inspector panel stays in sync.
final class LightManager: ObservableObject {

    static let maxLights = 4

    // Active light list — SwiftUI observers fire on add/remove and on any
    // element mutation because Array is a value type (copy-on-write).
    @Published var lights: [LightConfig] = []

    // Index of the light that keyboard arrows control.
    @Published var selectedIndex: Int = 0

    // Low-level ambient fill — additional to any Ambient-type light entries.
    // Kept for backward compatibility with pre-Phase-7 project files.
    var ambientColor: SIMD3<Float> = SIMD3<Float>(0.04, 0.04, 0.06)

    // MARK: - Init

    init() {
        lights = [.defaultDirectional]
        print("[DEBUG] LightManager: initialized — 1 directional light")
    }

    // MARK: - Selection

    var selectedLight: LightConfig? {
        guard selectedIndex < lights.count else { return nil }
        return lights[selectedIndex]
    }

    func cycleSelection() {
        guard lights.count > 1 else {
            print("[DEBUG] LightManager: cycleSelection — only one light")
            return
        }
        selectedIndex = (selectedIndex + 1) % lights.count
        print("[DEBUG] LightManager: selected light " + String(selectedIndex)
            + " (" + (selectedLight?.type.displayName ?? "none") + ")")
    }

    // MARK: - Add / remove

    func addLight(_ light: LightConfig) {
        guard lights.count < Self.maxLights else {
            print("[DEBUG] LightManager: addLight — max lights reached")
            return
        }
        lights.append(light)
        selectedIndex = lights.count - 1
        print("[DEBUG] LightManager: added " + light.type.displayName
            + " total=" + String(lights.count))
    }

    func removeLight(at index: Int) {
        guard index >= 0, index < lights.count, lights.count > 1 else {
            print("[DEBUG] LightManager: removeLight — invalid index or last light")
            return
        }
        lights.remove(at: index)
        if selectedIndex >= lights.count { selectedIndex = lights.count - 1 }
        print("[DEBUG] LightManager: removed light at index " + String(index))
    }

    // MARK: - Keyboard control (Phase 6/7)

    // Rotates/moves the selected light according to its type.
    //   • Directional / spot / laser — rotates direction vector
    //   • Point — moves position horizontally and vertically
    //   • Ambient — no-op
    func rotateSelected(deltaAzimuth: Float, deltaElevation: Float) {
        guard selectedIndex < lights.count else { return }
        var light = lights[selectedIndex]

        switch light.type {
        case .ambient:
            return

        case .directional, .spot, .laser:
            var dir = light.direction
            if abs(deltaAzimuth) > 0.0001 {
                let c = cos(deltaAzimuth), s = sin(deltaAzimuth)
                let nx = dir.x * c + dir.z * s
                let nz = -dir.x * s + dir.z * c
                dir = SIMD3<Float>(nx, dir.y, nz)
            }
            if abs(deltaElevation) > 0.0001 {
                let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), dir))
                let c     = cos(deltaElevation), s = sin(deltaElevation)
                let dot   = simd_dot(right, dir)
                let cross = simd_cross(right, dir)
                dir = dir * c + cross * s + right * (dot * (1 - c))
            }
            let xzLen = sqrt(dir.x * dir.x + dir.z * dir.z)
            if xzLen < 0.01 { dir.y = dir.y > 0 ? 0.98 : -0.98; dir.x = 0.1 }
            light.direction = simd_normalize(dir)
            print("[DEBUG] LightManager: direction=("
                + String(format: "%.2f", light.direction.x) + ","
                + String(format: "%.2f", light.direction.y) + ","
                + String(format: "%.2f", light.direction.z) + ")")

        case .point:
            light.position.x += deltaAzimuth  * 0.3
            light.position.y -= deltaElevation * 0.3
            print("[DEBUG] LightManager: position=("
                + String(format: "%.2f", light.position.x) + ","
                + String(format: "%.2f", light.position.y) + ","
                + String(format: "%.2f", light.position.z) + ")")
        }

        lights[selectedIndex] = light
    }

    // Moves the selected positional light in/out along its direction (+/- keys).
    func moveSelectedDepth(delta: Float) {
        guard selectedIndex < lights.count else { return }
        switch lights[selectedIndex].type {
        case .point, .spot, .laser:
            lights[selectedIndex].position += lights[selectedIndex].direction * delta
        default:
            break
        }
    }

    // Adjusts intensity of the selected light, clamped to [0, 20].
    func adjustSelectedIntensity(delta: Float) {
        guard selectedIndex < lights.count else { return }
        lights[selectedIndex].intensity =
            max(0.0, min(20.0, lights[selectedIndex].intensity + delta))
        print("[DEBUG] LightManager: intensity="
            + String(format: "%.2f", lights[selectedIndex].intensity))
    }

    // MARK: - Backward-compat accessors (used by VideoExporter pre-Phase-7 paths)

    var primaryLight: LightConfig {
        return lights.first ?? .defaultDirectional
    }

    var ambientColorVec4: SIMD4<Float> {
        return SIMD4<Float>(ambientColor, 0)
    }

    // MARK: - Shader data

    // Builds the LightUniforms block that the fragment shader reads from buffer(3).
    func buildLightUniforms() -> LightUniforms {
        var u = LightUniforms()
        u.ambientColor = SIMD4<Float>(ambientColor, 0)

        let enabled = lights.filter { $0.isEnabled }
        let count   = min(enabled.count, Self.maxLights)
        u.countAndPad = SIMD4<UInt32>(UInt32(count), 0, 0, 0)

        for (i, light) in enabled.prefix(Self.maxLights).enumerated() {
            u.setLight(light.shaderLight, at: i)
        }

        return u
    }
}
