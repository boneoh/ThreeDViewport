import Metal
import MetalKit
import simd

// MTKViewDelegate that owns the Metal pipeline and issues draw calls.
// Phase 2: also ticks the Timeline and applies keyframe evaluation each frame.
// Phase 7: multi-light via LightUniforms buffer(3); background gradient pass.
final class Renderer: NSObject, MTKViewDelegate {

    // MARK: - Metal state

    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    // Scene geometry pipeline (vertex_main / fragment_main)
    var pipelineState: MTLRenderPipelineState?
    var depthStencilState: MTLDepthStencilState?

    // Background gradient pipeline (background_vertex / background_fragment)
    var backgroundPipelineState: MTLRenderPipelineState?
    var backgroundDepthState: MTLDepthStencilState?   // always-pass, no depth write

    // MARK: - Scene references

    let sceneManager: SceneManager
    let camera: CameraController
    let lightManager: LightManager
    let backgroundConfig: BackgroundConfig
    let timeline: Timeline

    // MARK: - Render mode

    var isWireframe: Bool = false

    // Tracks the last timeline time at which keyframes were evaluated.
    private var lastAnimatedTime: Double = -1.0

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
            print("[DEBUG] Renderer: MTLDevice.makeCommandQueue returned nil")
            return nil
        }
        self.commandQueue = queue

        super.init()
        buildPipeline()
    }

    // MARK: - Pipeline setup

    private func buildPipeline() {
        guard let library = try? device.makeDefaultLibrary(bundle: Bundle.module) else {
            print("[DEBUG] Renderer: makeDefaultLibrary(bundle:) failed")
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
            print("[DEBUG] Renderer: scene pipeline state created")
        } catch {
            print("[DEBUG] Renderer: scene pipeline failed — " + error.localizedDescription)
        }

        let depthDesc = MTLDepthStencilDescriptor()
        depthDesc.depthCompareFunction = .less
        depthDesc.isDepthWriteEnabled  = true
        depthStencilState = device.makeDepthStencilState(descriptor: depthDesc)

        // ── Background gradient pipeline ──────────────────────────────────────
        guard let bgVertFn   = library.makeFunction(name: "background_vertex"),
              let bgFragFn   = library.makeFunction(name: "background_fragment") else {
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
            print("[DEBUG] Renderer: background pipeline state created")
        } catch {
            print("[DEBUG] Renderer: background pipeline failed — " + error.localizedDescription)
        }

        // Background depth state: always pass, never write — quad sits behind all geometry
        let bgDepthDesc = MTLDepthStencilDescriptor()
        bgDepthDesc.depthCompareFunction = .always
        bgDepthDesc.isDepthWriteEnabled  = false
        backgroundDepthState = device.makeDepthStencilState(descriptor: bgDepthDesc)

        if depthStencilState == nil || backgroundDepthState == nil {
            print("[DEBUG] Renderer: one or more depth states are nil")
        }
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        camera.aspectRatio = Float(size.width / size.height)
        print("[DEBUG] Renderer: drawable size " + String(Int(size.width))
            + "x" + String(Int(size.height)))
    }

    func draw(in view: MTKView) {

        // ── Phase 2: advance timeline and evaluate keyframes ─────────────────
        timeline.tick()
        if timeline.currentTime != lastAnimatedTime {
            applyAnimation()
            lastAnimatedTime = timeline.currentTime
        }

        // ── Clear colour from background config ───────────────────────────────
        // For solid mode this IS the final colour; for gradient mode it fills any
        // pixel below the gradient quad (normally none, but avoids black gaps).
        view.clearColor = backgroundConfig.clearColor

        // ── Acquire Metal resources ───────────────────────────────────────────
        guard let pipeline        = pipelineState else { return }

        guard let drawable        = view.currentDrawable,
              let passDescriptor  = view.currentRenderPassDescriptor,
              let commandBuffer   = commandQueue.makeCommandBuffer() else {
            print("[DEBUG] Renderer: draw — failed to acquire Metal resources")
            return
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            print("[DEBUG] Renderer: makeRenderCommandEncoder returned nil")
            commandBuffer.commit()
            return
        }

        // ── Background gradient pass ──────────────────────────────────────────
        // Drawn first so scene geometry always appears in front.
        if backgroundConfig.mode == .gradient,
           let bgPipeline   = backgroundPipelineState,
           let bgDepthState = backgroundDepthState {

            encoder.setRenderPipelineState(bgPipeline)
            encoder.setDepthStencilState(bgDepthState)
            encoder.setCullMode(.none)

            var bgUniforms = backgroundConfig.backgroundUniforms
            encoder.setFragmentBytes(&bgUniforms,
                                     length: MemoryLayout<BackgroundUniforms>.stride,
                                     index: 0)
            // background_vertex generates the quad from vertex_id — no vertex buffer needed
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        // ── Early-out if no visible geometry ─────────────────────────────────
        let visibleObjects = sceneManager.objects.filter { $0.isVisible }
        guard !visibleObjects.isEmpty else {
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

        // ── Scene geometry pass ───────────────────────────────────────────────
        encoder.setRenderPipelineState(pipeline)
        if let ds = depthStencilState { encoder.setDepthStencilState(ds) }

        // Build and bind LightUniforms once for all objects (buffer index 3)
        var lightUniforms = lightManager.buildLightUniforms()
        encoder.setFragmentBytes(&lightUniforms,
                                 length: MemoryLayout<LightUniforms>.stride,
                                 index: 3)

        let vp = camera.viewProjectionMatrix

        for object in visibleObjects {

            guard let posBuffer = object.positionBuffer else {
                print("[DEBUG] Renderer: positionBuffer nil for '" + object.name + "' — skipping")
                continue
            }
            guard let idxBuffer = object.indexBuffer else {
                print("[DEBUG] Renderer: indexBuffer nil for '" + object.name + "' — skipping")
                continue
            }
            if object.indexCount == 0 {
                print("[DEBUG] Renderer: indexCount zero for '" + object.name + "' — skipping")
                continue
            }

            var uniforms = Uniforms(
                modelMatrix:          object.transform,
                viewProjectionMatrix: vp,
                normalMatrix:         object.transform
            )

            encoder.setVertexBuffer(posBuffer, offset: 0, index: 0)

            if let normBuffer = object.normalBuffer {
                encoder.setVertexBuffer(normBuffer, offset: 0, index: 1)
            } else {
                print("[DEBUG] Renderer: normalBuffer nil for '" + object.name + "'")
            }

            encoder.setVertexBytes(&uniforms,   length: MemoryLayout<Uniforms>.stride, index: 2)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)

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
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Animation evaluation

    private func applyAnimation() {
        // ── Object keyframes ──────────────────────────────────────────────────
        for object in sceneManager.objects {
            guard let track = object.keyframeTrack else { continue }
            if track.keyframes.isEmpty { continue }
            if let animDelta = track.evaluate(at: timeline.currentTime) {
                object.transform = object.baseTransform * animDelta
            }
        }

        // ── Camera keyframes (Phase 5) ────────────────────────────────────────
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
