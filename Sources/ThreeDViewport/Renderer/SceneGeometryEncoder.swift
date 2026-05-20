import Metal
import simd

// Single source of truth for encoding scene geometry.
// BOTH the live `Renderer` and the offline `VideoExporter` call this so material,
// normal-mode, and IBL handling can never drift between preview and export again.
//
// (Previously each had its own copy of the draw loop; the export silently missed
// flat-normal shading and IBL because of that duplication.)
enum SceneGeometryEncoder {

    // Per-pass context that differs between the live view and the exporter
    // (camera, target color mode, the IBL instance, fallback buffers, …).
    struct Context {
        let viewProjection:    matrix_float4x4
        let eyePosition:       SIMD3<Float>
        let pipelineState:     MTLRenderPipelineState
        let depthStencilState: MTLDepthStencilState
        let isColorMode:       Bool
        let isWireframe:       Bool
        let ibl:               IBL?
        let dummyUV:           MTLBuffer?
        let dummyTangent:      MTLBuffer?
    }

    // Encodes every visible object into `encoder`.  Binds light + IBL state once,
    // then per-object uniforms/material/textures and the draw call.
    static func encode(into encoder: MTLRenderCommandEncoder,
                       objects: [SceneObject],
                       groupTransforms: [Int: matrix_float4x4],
                       lightUniforms: LightUniforms,
                       context: Context) {

        let visible = objects.filter { $0.isVisible }
        guard !visible.isEmpty else { return }

        encoder.setRenderPipelineState(context.pipelineState)
        encoder.setDepthStencilState(context.depthStencilState)
        encoder.setTriangleFillMode(context.isWireframe ? .lines : .fill)

        // ── Light + IBL (constant across all objects this pass) ────────────────
        // IBL intensity rides in the spare ambientColor.w slot; forced to 0 if any
        // IBL texture is missing so the shader never samples an unbound slot.
        var lu = lightUniforms
        let iblReady = context.ibl?.irradianceCube != nil
                    && context.ibl?.specularCube   != nil
                    && context.ibl?.brdfLUT        != nil
        lu.ambientColor.w = iblReady ? (context.ibl?.intensity ?? 0.0) : 0.0
        encoder.setFragmentBytes(&lu,
                                 length: MemoryLayout<LightUniforms>.stride,
                                 index: 3)

        if iblReady, let i = context.ibl {
            encoder.setFragmentTexture(i.irradianceCube, index: 4)
            encoder.setFragmentTexture(i.specularCube,   index: 5)
            encoder.setFragmentTexture(i.brdfLUT,        index: 6)
        }

        // ── Per-object ─────────────────────────────────────────────────────────
        for object in visible {
            guard let posBuffer = object.positionBuffer,
                  let idxBuffer = object.indexBuffer,
                  object.indexCount > 0 else { continue }

            // Group-level transform layer on top of the per-part transform.
            let modelMatrix: matrix_float4x4
            if let gid = object.groupID, let gt = groupTransforms[gid] {
                modelMatrix = gt * object.transform
            } else {
                modelMatrix = object.transform
            }
            let normalMatrix = simd_transpose(simd_inverse(modelMatrix))

            var uniforms = Uniforms(
                modelMatrix:          modelMatrix,
                viewProjectionMatrix: context.viewProjection,
                normalMatrix:         normalMatrix,
                cameraPosition:       SIMD4<Float>(context.eyePosition.x,
                                                   context.eyePosition.y,
                                                   context.eyePosition.z, 0))

            encoder.setVertexBuffer(posBuffer, offset: 0, index: 0)
            if let n = object.normalBuffer { encoder.setVertexBuffer(n, offset: 0, index: 1) }
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)

            let uvBuf  = object.uvBuffer      ?? context.dummyUV
            let tanBuf = object.tangentBuffer ?? context.dummyTangent
            encoder.setVertexBuffer(uvBuf,  offset: 0, index: 4)
            encoder.setVertexBuffer(tanBuf, offset: 0, index: 5)

            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)

            var mu = buildMaterialUniforms(for: object, isColorMode: context.isColorMode)
            encoder.setFragmentBytes(&mu,
                                     length: MemoryLayout<MaterialUniforms>.stride,
                                     index: 4)

            bindMaterialTextures(encoder: encoder, material: object.material)

            encoder.drawIndexedPrimitives(type:              .triangle,
                                          indexCount:        object.indexCount,
                                          indexType:         .uint32,
                                          indexBuffer:       idxBuffer,
                                          indexBufferOffset: 0)
        }
    }

    // MARK: - Helpers (shared so preview/export build identical uniforms)

    static func buildMaterialUniforms(for object: SceneObject,
                                      isColorMode: Bool) -> MaterialUniforms {
        let mat = object.material
        var mu  = MaterialUniforms()
        mu.baseColorFactor     = mat.baseColorFactor
        mu.emissiveFactor      = SIMD4<Float>(mat.emissiveFactor.x,
                                              mat.emissiveFactor.y,
                                              mat.emissiveFactor.z, 0)
        mu.metallicFactor      = mat.metallicFactor
        mu.roughnessFactor     = mat.roughnessFactor
        mu.hasBaseColorTex     = mat.baseColorTexture         != nil ? 1 : 0
        mu.hasNormalTex        = mat.normalTexture            != nil ? 1 : 0
        mu.hasMetallicRoughTex = mat.metallicRoughnessTexture != nil ? 1 : 0
        mu.hasEmissiveTex      = mat.emissiveTexture          != nil ? 1 : 0
        mu.colorMode           = isColorMode ? 1 : 0

        // Flat shading: explicit user pick, or .auto on a file with no normals.
        let wantFlat = object.normalMode == .flat
                    || (object.normalMode == .auto && !object.fileHadNormals)
        mu.useFlatNormals = wantFlat ? 1 : 0
        return mu
    }

    static func bindMaterialTextures(encoder: MTLRenderCommandEncoder,
                                     material: PBRMaterial) {
        if let t = material.baseColorTexture          { encoder.setFragmentTexture(t, index: 0) }
        if let t = material.normalTexture             { encoder.setFragmentTexture(t, index: 1) }
        if let t = material.metallicRoughnessTexture  { encoder.setFragmentTexture(t, index: 2) }
        if let t = material.emissiveTexture           { encoder.setFragmentTexture(t, index: 3) }
    }
}
