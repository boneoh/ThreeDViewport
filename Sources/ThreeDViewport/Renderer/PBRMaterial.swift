import Foundation
import Metal
import simd

/// The original encoded image bytes (PNG / JPEG) + mime type for a loaded texture,
/// retained at load so the GLB exporter can re-embed it losslessly (no readback).
struct TextureSource {
    let data:     Data
    let mimeType: String   // "image/png" or "image/jpeg"
}

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

    // ── Retained encoded image bytes (for GLB export) ─────────────────────────
    // The original PNG/JPEG bytes for each texture slot, kept so the model
    // exporter can re-embed them; nil when the slot has no texture.
    var baseColorSource:         TextureSource?
    var metallicRoughnessSource: TextureSource?
    var normalSource:            TextureSource?
    var emissiveSource:          TextureSource?
}
