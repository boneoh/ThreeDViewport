import Metal
import simd

// Represents one loaded GLTF mesh node with its GPU buffers.
// Phase 2 will add animation keyframes; Phase 3 will add multi-object management.
final class SceneObject {

    let name: String

    // Local-to-world transform (set by GLTFLoader from node hierarchy)
    var transform: matrix_float4x4

    // GPU buffers — positions and normals are tightly-packed float3 arrays
    var positionBuffer: MTLBuffer?
    var normalBuffer: MTLBuffer?
    var indexBuffer: MTLBuffer?   // UInt32 indices
    var indexCount: Int

    var isVisible: Bool

    // Bounding sphere (computed during load for camera fitting)
    var boundingCenter: SIMD3<Float>
    var boundingRadius: Float

    init(name: String) {
        self.name          = name
        self.transform     = matrix_identity_float4x4
        self.indexCount    = 0
        self.isVisible     = true
        self.boundingCenter = SIMD3<Float>(0, 0, 0)
        self.boundingRadius = 1.0

        print("[DEBUG] SceneObject: created '" + name + "'")
    }

    // Sanity check — call after population to surface nil buffers early
    func validateBuffers() {
        if positionBuffer == nil {
            print("[DEBUG] SceneObject '" + name + "': positionBuffer is nil")
        }
        if normalBuffer == nil {
            print("[DEBUG] SceneObject '" + name + "': normalBuffer is nil")
        }
        if indexBuffer == nil {
            print("[DEBUG] SceneObject '" + name + "': indexBuffer is nil")
        }
        if indexCount == 0 {
            print("[DEBUG] SceneObject '" + name + "': indexCount is zero")
        }
    }
}
