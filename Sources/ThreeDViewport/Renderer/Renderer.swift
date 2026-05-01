import Metal
import MetalKit
import simd

// MTKViewDelegate that owns the Metal pipeline and issues draw calls.
// Phase 1: lit triangles + wireframe toggle.
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

    // MARK: - Render mode

    var isWireframe: Bool = false

    // MARK: - Init

    init?(device: MTLDevice,
          sceneManager: SceneManager,
          camera: CameraController,
          lightManager: LightManager) {

        self.device       = device
        self.sceneManager = sceneManager
        self.camera       = camera
        self.lightManager = lightManager

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
        // Load the Metal library compiled from Shaders.metal in this SPM bundle
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
        // Pixel formats must match what ViewportView sets on the MTKView
        pipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDesc.depthAttachmentPixelFormat      = .depth32Float
        // No vertex descriptor — positions/normals are bound via explicit buffer indices

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDesc)
            print("[DEBUG] Renderer: pipeline state created successfully")
        } catch {
            print("[DEBUG] Renderer: makeRenderPipelineState failed — " + error.localizedDescription)
        }

        // Depth stencil — standard less-than depth test
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
        print("[DEBUG] Renderer: drawable size changed to " + String(Int(size.width)) + "x" + String(Int(size.height)))
    }

    func draw(in view: MTKView) {
        guard let pipeline = pipelineState else {
            // Pipeline not ready — silently skip (already logged at build time)
            return
        }

        guard let drawable          = view.currentDrawable,
              let passDescriptor    = view.currentRenderPassDescriptor,
              let commandBuffer     = commandQueue.makeCommandBuffer() else {
            print("[DEBUG] Renderer: draw — failed to acquire drawable, passDescriptor, or commandBuffer")
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
        } else {
            print("[DEBUG] Renderer: depthStencilState is nil — depth testing disabled this frame")
        }

        let vp = camera.viewProjectionMatrix

        if sceneManager.objects.isEmpty {
            // Nothing loaded yet — just clear and present
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

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
                print("[DEBUG] Renderer: indexCount is zero for '" + object.name + "' — skipping")
                continue
            }

            // Build per-draw uniforms
            var uniforms = Uniforms(
                modelMatrix:          object.transform,
                viewProjectionMatrix: vp,
                normalMatrix:         object.transform,   // valid for uniform scale
                lightDirection:       lightManager.primaryLight.directionVec4,
                lightColor:           lightManager.primaryLight.colorVec4,
                ambientColor:         lightManager.ambientColorVec4
            )

            // Bind vertex buffers (positions at 0, normals at 1, uniforms at 2)
            encoder.setVertexBuffer(posBuffer, offset: 0, index: 0)

            if let normBuffer = object.normalBuffer {
                encoder.setVertexBuffer(normBuffer, offset: 0, index: 1)
            } else {
                print("[DEBUG] Renderer: normalBuffer nil for '" + object.name + "' — normals unbound")
            }

            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)

            // Wireframe is a fill-mode switch, not a separate pipeline
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
}
