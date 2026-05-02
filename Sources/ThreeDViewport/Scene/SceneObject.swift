import Metal
import simd

// Represents one loaded GLTF mesh node with its GPU buffers.
// Phase 2 adds keyframe animation via keyframeTrack.
// Phase 6 adds sourceURL and per-object visibility toggle.
final class SceneObject {

    let name: String

    // The .glb file this object was loaded from.
    // Stored so multi-model project files can reload each object independently.
    var sourceURL: URL?

    // The world transform used for rendering each frame.
    // Updated by the Renderer when animation is active.
    var transform: matrix_float4x4

    // The original world transform set by GLTFLoader (after autoNormalize).
    // The animation system multiplies baseTransform * animationDelta each frame.
    // When no animation is active, transform == baseTransform.
    var baseTransform: matrix_float4x4

    // Phase 2: optional keyframe animation track.
    // Nil means the object uses baseTransform unchanged.
    var keyframeTrack: KeyframeTrack?

    // GPU buffers — positions and normals are tightly-packed float3 arrays
    var positionBuffer: MTLBuffer?
    var normalBuffer: MTLBuffer?
    var indexBuffer: MTLBuffer?   // UInt32 indices
    var indexCount: Int

    var isVisible: Bool

    // Bounding sphere (world space, set by GLTFLoader + autoNormalize)
    var boundingCenter: SIMD3<Float>
    var boundingRadius: Float

    init(name: String) {
        self.name          = name
        self.transform     = matrix_identity_float4x4
        self.baseTransform = matrix_identity_float4x4
        self.indexCount    = 0
        self.isVisible     = true
        self.boundingCenter = SIMD3<Float>(0, 0, 0)
        self.boundingRadius = 1.0

        print("[DEBUG] SceneObject: created '" + name + "'")
    }

    // Sanity check — call after population to surface nil buffers early.
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
