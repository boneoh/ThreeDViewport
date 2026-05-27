import Metal
import simd

// Phase 8: PBR material data for one mesh primitive.
// Holds both the factor values (scalars / vectors) and any loaded MTLTextures.
// Flags are mirrored into MaterialUniforms so the shader can branch on them.
struct PBRMaterial {

    // ── Base color (albedo) ───────────────────────────────────────────────────
    var baseColorFactor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)
    var baseColorTexture: MTLTexture?

    // ── Metallic / roughness (glTF packed: B=metallic, G=roughness) ───────────
    var metallicFactor:           Float = 0.0    // dielectric by default
    var roughnessFactor:          Float = 0.5    // medium roughness by default
    var metallicRoughnessTexture: MTLTexture?

    // ── Normal map ────────────────────────────────────────────────────────────
    var normalTexture: MTLTexture?

    // ── Emissive ──────────────────────────────────────────────────────────────
    var emissiveFactor:  SIMD3<Float> = SIMD3<Float>(0, 0, 0)
    var emissiveTexture: MTLTexture?

    // User-controllable opacity (0 = fully transparent, 1 = fully opaque).
    // Independent of baseColorFactor.w; the shader multiplies the two.
    var opacity: Float = 1
}
