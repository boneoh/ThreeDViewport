import Metal
import MetalKit
import simd

// MTKViewDelegate that owns the Metal pipeline and issues draw calls.
// Phase 2: also ticks the Timeline and applies keyframe evaluation each frame.
final class Renderer: NSObject, MTKViewDelegate {

    // MARK: - Metal state

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    var pipelineState: MTLRenderPipelineState?
    var depthStencilState: MTLDepthStencilState?

    // MARK: - Scene references

    let sceneManager: SceneManager
    let camera: CameraController
    let lightManager: LightManager
    let timeline: Timeline

    // MARK: - Render mode

    var isWireframe: Bool = false

    // Tracks the last timeline time at which keyframes were evaluated.
    // applyAnimation() is only called when time changes (playing or scrubbed),
    // so a paused object keeps whatever transform the user set manually.
    private var lastAnimatedTime: Double = -1.0

    // MARK: - Init

    init?(device: MTLDevice,
          sceneManager: SceneManager,
          camera: CameraController,
          lightManager: LightManager,
          timeline: Timeline) {

        self.device       = device
        self.sceneManager = sceneManager
        self.camera       = camera
        self.lightManager = lightManager
        self.timeline     = timeline

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
            print("[DEBUG] Renderer: makeDefaultLibrary(bundle:) failed — Shaders.metal may not be compiled into Bundle.module")
            return
        }

        guard let vertexFn = library.makeFunction(name: "vertex_main") else {
            print("[DEBUG] Renderer: vertex_main not found in Metal library")
            return
        }

        guard let fragmentFn = library.makeFunction(name: "fragment_main") else {
            print("[DEBUG] Renderer: fragment_main not found in Metal library")
            return
        }

        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.vertexFunction   = vertexFn
        pipelineDesc.fragmentFunction = fragmentFn
        pipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDesc.depthAttachmentPixelFormat      = .depth32Float

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDesc)
            print("[DEBUG] Renderer: pipeline state created successfully")
        } catch {
            print("[DEBUG] Renderer: makeRenderPipelineState failed — " + error.localizedDescription)
        }

        let depthDesc = MTLDepthStencilDescriptor()
        depthDesc.depthCompareFunction = .less
        depthDesc.isDepthWriteEnabled  = true
        depthStencilState = device.makeDepthStencilState(descriptor: depthDesc)

        if depthStencilState == nil {
            print("[DEBUG] Renderer: makeDepthStencilState returned nil")
        }
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        camera.aspectRatio = Float(size.width / size.height)
        print("[DEBUG] Renderer: drawable size changed to "
            + String(Int(size.width)) + "x" + String(Int(size.height)))
    }

    func draw(in view: MTKView) {

        // ── Phase 2: advance timeline and evaluate keyframes ─────────────────
        timeline.tick()
        applyAnimation()

        // ── Metal rendering ───────────────────────────────────────────────────
        guard let pipeline = pipelineState else { return }

        guard let drawable       = view.currentDrawable,
              let passDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer  = commandQueue.makeCommandBuffer() else {
            print("[DEBUG] Renderer: draw — failed to acquire drawable/passDescriptor/commandBuffer")
            return
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            print("[DEBUG] Renderer: makeRenderCommandEncoder returned nil")
            commandBuffer.commit()
            return
        }

        encoder.setRenderPipelineState(pipeline)

        if let ds = depthStencilState {
            encoder.setDepthStencilState(ds)
        }

        if sceneManager.objects.isEmpty {
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

        let vp = camera.viewProjectionMatrix

        for object in sceneManager.objects {
            guard object.isVisible else { continue }

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
                normalMatrix:         object.transform,
                lightDirection:       lightManager.primaryLight.directionVec4,
                lightColor:           lightManager.primaryLight.colorVec4,
                ambientColor:         lightManager.ambientColorVec4
            )

            encoder.setVertexBuffer(posBuffer, offset: 0, index: 0)

            if let normBuffer = object.normalBuffer {
                encoder.setVertexBuffer(normBuffer, offset: 0, index: 1)
            } else {
                print("[DEBUG] Renderer: normalBuffer nil for '" + object.name + "'")
            }

            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
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
        for object in sceneManager.objects {
            guard let track = object.keyframeTrack else { continue }

            if track.keyframes.isEmpty {
                print("[DEBUG] Renderer: keyframeTrack for '" + object.name + "' has no keyframes")
                continue
            }

            if let animDelta = track.evaluate(at: timeline.currentTime) {
                // animDelta is a local T*R*S animation matrix (typically a rotation delta).
                // Composing with baseTransform applies position/scale first, then animation.
                object.transform = object.baseTransform * animDelta
            }
        }
    }
}
