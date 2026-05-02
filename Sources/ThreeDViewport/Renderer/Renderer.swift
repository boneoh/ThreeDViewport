import Metal
import MetalKit
import simd

// MTKViewDelegate that owns the Metal pipeline and issues draw calls.
// Phase 7: multi-light, background gradient.
// Phase 8: PBR materials, UV/tangent buffers, MaterialUniforms, color/greyscale mode.
final class Renderer: NSObject, MTKViewDelegate {

    // MARK: - Metal state

    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    // Scene geometry pipeline
    var pipelineState: MTLRenderPipelineState?
    var depthStencilState: MTLDepthStencilState?

    // Background gradient pipeline
    var backgroundPipelineState: MTLRenderPipelineState?
    var backgroundDepthState: MTLDepthStencilState?

    // Fallback buffers — bound when an object has no UVs or tangents so
    // buffer(4)/buffer(5) are always valid Metal bindings.
    private var dummyUVBuffer:      MTLBuffer?   // single float2
    private var dummyTangentBuffer: MTLBuffer?   // single float4

    // MARK: - Scene references

    let sceneManager:     SceneManager
    let camera:           CameraController
    let lightManager:     LightManager
    let backgroundConfig: BackgroundConfig
    let timeline:         Timeline

    // MARK: - Render mode

    var isWireframe: Bool = false
    var isColorMode: Bool = false   // false = greyscale (default)

    // MARK: - Feedback (optional — set by ViewportView after init)

    var feedbackProcessor: FeedbackProcessor?
    var feedbackSettings:  FeedbackSettings?

    private var lastAnimatedTime: Double = -1.0

    // One-shot material diagnostics — prints once per object on the first draw
    private var materialDebugPrinted: Set<String> = []

    // MARK: - Init

    init?(device: MTLDevice,
          sceneManager: SceneManager,
          camera: CameraController,
          lightManager: LightManager,
          backgroundConfig: BackgroundConfig,
          timeline: Timeline) {

        self.device           = device
        self.sceneManager     = sceneManager
        self.camera           = camera
        self.lightManager     = lightManager
        self.backgroundConfig = backgroundConfig
        self.timeline         = timeline

        guard let queue = device.makeCommandQueue() else {
            print("[DEBUG] Renderer: makeCommandQueue returned nil")
            return nil
        }
        self.commandQueue = queue

        super.init()
        buildPipeline()
        buildDummyBuffers()
    }

    // MARK: - Pipeline setup

    private func buildPipeline() {
        guard let library = try? device.makeDefaultLibrary(bundle: Bundle.module) else {
            print("[DEBUG] Renderer: makeDefaultLibrary failed")
            return
        }

        // ── Scene geometry pipeline ───────────────────────────────────────────
        guard let vertexFn   = library.makeFunction(name: "vertex_main"),
              let fragmentFn = library.makeFunction(name: "fragment_main") else {
            print("[DEBUG] Renderer: vertex_main or fragment_main not found")
            return
        }

        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.vertexFunction   = vertexFn
        pipelineDesc.fragmentFunction = fragmentFn
        pipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDesc.depthAttachmentPixelFormat      = .depth32Float

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDesc)
            print("[DEBUG] Renderer: scene pipeline created")
        } catch {
            print("[DEBUG] Renderer: scene pipeline failed — " + error.localizedDescription)
        }

        let depthDesc = MTLDepthStencilDescriptor()
        depthDesc.depthCompareFunction = .less
        depthDesc.isDepthWriteEnabled  = true
        depthStencilState = device.makeDepthStencilState(descriptor: depthDesc)

        // ── Background gradient pipeline ──────────────────────────────────────
        guard let bgVertFn = library.makeFunction(name: "background_vertex"),
              let bgFragFn = library.makeFunction(name: "background_fragment") else {
            print("[DEBUG] Renderer: background shaders not found")
            return
        }

        let bgDesc = MTLRenderPipelineDescriptor()
        bgDesc.vertexFunction   = bgVertFn
        bgDesc.fragmentFunction = bgFragFn
        bgDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        bgDesc.depthAttachmentPixelFormat      = .depth32Float

        do {
            backgroundPipelineState = try device.makeRenderPipelineState(descriptor: bgDesc)
            print("[DEBUG] Renderer: background pipeline created")
        } catch {
            print("[DEBUG] Renderer: background pipeline failed — " + error.localizedDescription)
        }

        let bgDepthDesc = MTLDepthStencilDescriptor()
        bgDepthDesc.depthCompareFunction = .always
        bgDepthDesc.isDepthWriteEnabled  = false
        backgroundDepthState = device.makeDepthStencilState(descriptor: bgDepthDesc)
    }

    private func buildDummyBuffers() {
        var dummyUV:  [Float] = [0, 0]
        var dummyTan: [Float] = [1, 0, 0, 1]
        dummyUVBuffer      = device.makeBuffer(bytes: &dummyUV,
                                                length: 2 * MemoryLayout<Float>.stride,
                                                options: .storageModeShared)
        dummyTangentBuffer = device.makeBuffer(bytes: &dummyTan,
                                                length: 4 * MemoryLayout<Float>.stride,
                                                options: .storageModeShared)
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        camera.aspectRatio = Float(size.width / size.height)
        // Cap feedback textures at 1920×1080 to avoid excess GPU memory on Retina displays.
        let fw = min(Int(size.width),  1920)
        let fh = min(Int(size.height), 1080)
        feedbackProcessor?.resize(width: fw, height: fh,
                                  length: feedbackSettings?.length ?? 10)
    }

    func draw(in view: MTKView) {
        timeline.tick()
        if timeline.currentTime != lastAnimatedTime {
            applyAnimation()
            lastAnimatedTime = timeline.currentTime
        }

        view.clearColor = backgroundConfig.clearColor

        guard let pipeline      = pipelineState else { return }
        guard let drawable      = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        // When feedback is active render the scene to an intermediate texture;
        // FeedbackProcessor composites and blits to the drawable.
        let feedbackActive = (feedbackSettings?.isEnabled == true)
                           && (feedbackProcessor?.sceneTexture != nil)

        let passDescriptor: MTLRenderPassDescriptor
        if feedbackActive, let fp = feedbackProcessor,
           let sceneTex = fp.sceneTexture, let depthTex = fp.depthTexture {
            let desc = MTLRenderPassDescriptor()
            desc.colorAttachments[0].texture     = sceneTex
            desc.colorAttachments[0].loadAction  = .clear
            desc.colorAttachments[0].storeAction = .store
            desc.colorAttachments[0].clearColor  = backgroundConfig.clearColor
            desc.depthAttachment.texture         = depthTex
            desc.depthAttachment.loadAction      = .clear
            desc.depthAttachment.storeAction     = .dontCare
            desc.depthAttachment.clearDepth      = 1.0
            passDescriptor = desc
        } else {
            guard let pd = view.currentRenderPassDescriptor else {
                commandBuffer.commit(); return
            }
            passDescriptor = pd
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            commandBuffer.commit(); return
        }

        // ── Background gradient ───────────────────────────────────────────────
        if backgroundConfig.mode == .gradient,
           let bgPipe  = backgroundPipelineState,
           let bgDepth = backgroundDepthState {
            encoder.setRenderPipelineState(bgPipe)
            encoder.setDepthStencilState(bgDepth)
            encoder.setCullMode(.none)
            var bgUniforms = backgroundConfig.backgroundUniforms
            encoder.setFragmentBytes(&bgUniforms,
                                     length: MemoryLayout<BackgroundUniforms>.stride,
                                     index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        // ── Scene geometry ────────────────────────────────────────────────────
        let visibleObjects = sceneManager.objects.filter { $0.isVisible }
        guard !visibleObjects.isEmpty else {
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

        encoder.setRenderPipelineState(pipeline)
        if let ds = depthStencilState { encoder.setDepthStencilState(ds) }

        // LightUniforms — constant across all objects this frame
        var lightUniforms = lightManager.buildLightUniforms()
        encoder.setFragmentBytes(&lightUniforms,
                                 length: MemoryLayout<LightUniforms>.stride,
                                 index: 3)

        let vp  = camera.viewProjectionMatrix
        let eye = camera.eyePosition

        for object in visibleObjects {
            guard let posBuffer = object.positionBuffer,
                  let idxBuffer = object.indexBuffer,
                  object.indexCount > 0 else { continue }

            // Correct normal matrix: inverse-transpose of model matrix
            let normalMatrix = simd_transpose(simd_inverse(object.transform))

            var uniforms = Uniforms(
                modelMatrix:          object.transform,
                viewProjectionMatrix: vp,
                normalMatrix:         normalMatrix,
                cameraPosition:       SIMD4<Float>(eye.x, eye.y, eye.z, 0)
            )

            encoder.setVertexBuffer(posBuffer, offset: 0, index: 0)
            if let n = object.normalBuffer   { encoder.setVertexBuffer(n, offset: 0, index: 1) }
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)

            // UV buffer — use dummy if not present (keeps buffer(4) always valid)
            let uvBuf  = object.uvBuffer      ?? dummyUVBuffer
            let tanBuf = object.tangentBuffer ?? dummyTangentBuffer
            encoder.setVertexBuffer(uvBuf,  offset: 0, index: 4)
            encoder.setVertexBuffer(tanBuf, offset: 0, index: 5)

            // Fragment: Uniforms + LightUniforms already bound; add MaterialUniforms
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
            var matUniforms = buildMaterialUniforms(for: object)
            encoder.setFragmentBytes(&matUniforms,
                                     length: MemoryLayout<MaterialUniforms>.stride,
                                     index: 4)

            // Bind textures (always bind all slots; shader checks flags before sampling)
            bindTextures(encoder: encoder, material: object.material)

            encoder.setTriangleFillMode(isWireframe ? .lines : .fill)
            encoder.drawIndexedPrimitives(
                type:              .triangle,
                indexCount:        object.indexCount,
                indexType:         .uint32,
                indexBuffer:       idxBuffer,
                indexBufferOffset: 0
            )
        }

        encoder.endEncoding()

        // Feedback composite + blit to drawable (or straight blit when just enabled)
        if feedbackActive, let fp = feedbackProcessor, let fs = feedbackSettings {
            fp.process(commandBuffer: commandBuffer,
                       dest:          drawable.texture,
                       settings:      fs)
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Material helpers

    private func buildMaterialUniforms(for object: SceneObject) -> MaterialUniforms {
        let mat = object.material
        var mu  = MaterialUniforms()
        mu.baseColorFactor     = mat.baseColorFactor
        mu.emissiveFactor      = SIMD4<Float>(mat.emissiveFactor.x,
                                              mat.emissiveFactor.y,
                                              mat.emissiveFactor.z, 0)
        mu.metallicFactor      = mat.metallicFactor
        mu.roughnessFactor     = mat.roughnessFactor
        mu.hasBaseColorTex     = mat.baseColorTexture     != nil ? 1 : 0
        mu.hasNormalTex        = mat.normalTexture        != nil ? 1 : 0
        mu.hasMetallicRoughTex = mat.metallicRoughnessTexture != nil ? 1 : 0
        mu.hasEmissiveTex      = mat.emissiveTexture      != nil ? 1 : 0
        mu.colorMode           = isColorMode ? 1 : 0

        if !materialDebugPrinted.contains(object.name) {
            materialDebugPrinted.insert(object.name)
            print("[DEBUG] Renderer materialUniforms '\(object.name)'"
                + " hasBaseColorTex=\(mu.hasBaseColorTex)"
                + " hasNormalTex=\(mu.hasNormalTex)"
                + " hasMetallicRoughTex=\(mu.hasMetallicRoughTex)"
                + " hasEmissiveTex=\(mu.hasEmissiveTex)"
                + " colorMode=\(mu.colorMode)"
                + " metallic=\(String(format: "%.3f", mu.metallicFactor))"
                + " roughness=\(String(format: "%.3f", mu.roughnessFactor))"
                + " texNonNil=\(mat.baseColorTexture != nil)")
        }

        return mu
    }

    private func bindTextures(encoder: MTLRenderCommandEncoder, material: PBRMaterial) {
        if let t = material.baseColorTexture          { encoder.setFragmentTexture(t, index: 0) }
        if let t = material.normalTexture             { encoder.setFragmentTexture(t, index: 1) }
        if let t = material.metallicRoughnessTexture  { encoder.setFragmentTexture(t, index: 2) }
        if let t = material.emissiveTexture           { encoder.setFragmentTexture(t, index: 3) }
    }

    // MARK: - Animation evaluation

    private func applyAnimation() {
        for object in sceneManager.objects {
            guard let track = object.keyframeTrack,
                  !track.keyframes.isEmpty else { continue }
            if let delta = track.evaluate(at: timeline.currentTime) {
                object.transform = object.baseTransform * delta
            }
        }

        if let camTrack = camera.keyframeTrack, !camTrack.keyframes.isEmpty {
            if let state = camTrack.evaluate(at: timeline.currentTime) {
                camera.yaw      = state.yaw
                camera.pitch    = state.pitch
                camera.distance = state.distance
                camera.target   = state.target
            }
        }
    }
}
