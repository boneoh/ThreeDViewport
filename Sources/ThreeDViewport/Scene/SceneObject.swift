import Metal
import simd

enum NormalMode: Int, CaseIterable {
    case auto   = 0   // use file normals if present, otherwise generate flat
    case smooth = 1   // always generate smooth (averaged face normals)
    case flat   = 2   // always generate flat (per-face normals, faceted look)

    var displayName: String {
        switch self {
        case .auto:   return "Auto"
        case .smooth: return "Smooth"
        case .flat:   return "Flat"
        }
    }
}

// Production role of an object, used by the one-click "Export All" cycle to decide
// which passes show vs hold out each object.  Default `.background` so unclassified
// geometry behaves as set dressing (visible in Full/Scene, held out in solos).
enum ObjectClass: String, CaseIterable {
    case background
    case actor
    case macguffin

    var displayName: String {
        switch self {
        case .background: return "Background"
        case .actor:      return "Actor"
        case .macguffin:  return "MacGuffin"
        }
    }
}

// Represents one loaded GLTF mesh node with its GPU buffers.
// Phase 2 adds keyframe animation via keyframeTrack.
// Phase 6 adds sourceURL and per-object visibility toggle.
final class SceneObject {

    var name: String

    // The .glb file this object was loaded from.
    // Stored so multi-model project files can reload each object independently.
    var sourceURL: URL?

    // Parts that share a groupID move together in Model mode.
    // Nil = not part of any group (single-mesh models).
    var groupID: Int?

    // True for "envelope" null nodes — a geometryless transform parent created by
    // the Glue feature.  Members set their parentIndex to the envelope's index so
    // applyHierarchy() drives them as a unit.  Has no GPU buffers (indexCount == 0),
    // so the geometry encoder already skips it; this flag lets callers that iterate
    // all objects (director fit, etc.) recognise and skip it explicitly.
    var isEnvelope: Bool = false

    // The world transform used for rendering each frame.
    // For root parts (parentIndex == nil): directly driven by animation / interaction.
    // For hierarchical parts (parentIndex != nil): recomputed every frame by
    // Renderer.applyHierarchy() as  parent.transform × localTransform.
    var transform: matrix_float4x4

    // The original world/local transform set by GLTFLoader (after autoNormalize).
    // For root parts: world-space base transform (same meaning as before).
    // For hierarchical parts: base LOCAL transform relative to the parent part.
    // The animation system multiplies baseTransform × animationDelta each frame.
    var baseTransform: matrix_float4x4

    // FK hierarchy: index of the parent part within the same loaded model, or nil
    // for root parts.  When non-nil, `transform` is recomputed each frame as
    // parent.transform × localTransform by Renderer.applyHierarchy().
    var parentIndex: Int?

    // Local transform relative to the parent part's world space.
    // For root parts (parentIndex == nil): equals transform (same matrix).
    // Animation and Object-mode interaction modify localTransform directly;
    // applyHierarchy() then propagates the change to `transform` and children.
    var localTransform: matrix_float4x4

    // Phase 2: optional keyframe animation track.
    // Nil means the object uses baseTransform unchanged.
    var keyframeTrack: KeyframeTrack?

    // GPU buffers — positions and normals are tightly-packed float3 arrays
    var positionBuffer: MTLBuffer?
    var normalBuffer:   MTLBuffer?
    var uvBuffer:       MTLBuffer?   // packed float2 — TEXCOORD_0 (may be zeroed if absent)
    var tangentBuffer:  MTLBuffer?   // packed float4 — xyz=tangent, w=handedness (may be zeroed)
    var indexBuffer:    MTLBuffer?   // UInt32 indices
    var indexCount: Int

    // Phase 8: PBR material (textures + factor values)
    var material: PBRMaterial = PBRMaterial()

    var isVisible: Bool

    // Holdout: when the object is hidden (isVisible == false) but this is true, it
    // is still rendered depth-only — occluding objects behind it without drawing
    // itself.  Used to "bite holes" out of mattes for later compositing.
    // Defaults ON for new objects (no effect until hidden); saved per-object so
    // existing projects keep their stored value and old pre-v17 files stay off.
    var occludeWhenHidden: Bool = true

    // Production role for the "Export All" multi-pass cycle (Model Inspector).
    var objectClass: ObjectClass = .background

    // Per-object feedback opt-in (Effects grid).  When feedback is active, objects
    // with this ON render into the feedback scene texture (they trail); objects with
    // it OFF are drawn after the feedback composite (crisp, no trail).  Defaults ON
    // so existing projects keep today's "everything trails" behaviour.
    var feedbackEnabled: Bool = true

    // Normal shading mode — set by the Model Inspector.
    // cpuPositions, cpuIndices, and originalNormals are kept so the GPU normal
    // buffer can be regenerated on demand without re-reading the .glb file.
    var normalMode:      NormalMode  = .auto
    var cpuPositions:    [Float]     = []
    var cpuIndices:      [UInt32]    = []
    var originalNormals: [Float]     = []   // normals as-loaded from file (or initial smooth)
    // True when the source .glb actually shipped a NORMAL accessor.
    // Drives the shader's flat-normal fallback when normalMode == .auto.
    var fileHadNormals:  Bool        = true

    // Bounding sphere (local space, set by GLTFLoader)
    var boundingCenter: SIMD3<Float>
    var boundingRadius: Float

    // Axis-aligned bounding box in LOCAL object space (set by GLTFLoader).
    // Used by LaserHitSystem for tighter ray-OBB intersection tests.
    var boundingMin: SIMD3<Float>
    var boundingMax: SIMD3<Float>

    init(name: String) {
        self.name           = name
        self.transform      = matrix_identity_float4x4
        self.baseTransform  = matrix_identity_float4x4
        self.parentIndex    = nil
        self.localTransform = matrix_identity_float4x4
        self.indexCount     = 0
        self.isVisible     = true
        self.boundingCenter = SIMD3<Float>(0, 0, 0)
        self.boundingRadius = 1.0
        self.boundingMin   = SIMD3<Float>(-1, -1, -1)
        self.boundingMax   = SIMD3<Float>( 1,  1,  1)

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
