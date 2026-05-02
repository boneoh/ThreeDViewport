import Metal
import QuartzCore

// Implements a video delay-line feedback loop using a Metal ring buffer.
//
// Architecture
// ────────────
// sceneTexture   — the 3D scene renders here each frame (instead of the drawable)
//                  when feedback is active.
// queue          — ring buffer of `length` textures, one per feedback interval.
// outputTexture  — temporary blend result (scene + oldest queue frame).
//
// Per feedback-interval tick:
//   Priming (queue not yet full):
//     • Copy sceneTexture → queue[writeIndex]        (store raw scene)
//     • Display sceneTexture unchanged.
//   Active (queue full):
//     • Blend(sceneTexture, queue[writeIndex]) → outputTexture   (decay weight)
//     • Copy outputTexture → queue[writeIndex]        (replace oldest slot)
//     • Display outputTexture.
//   Advance writeIndex; set isFull when it first wraps to 0.
//
// On non-feedback frames (frameCounter % interval ≠ 0):
//   Scene is displayed unchanged — no queue read/write.

final class FeedbackProcessor {

    let device: MTLDevice

    // ── Offscreen render targets ──────────────────────────────────────────────

    /// Scene renders here when feedback is active (instead of the drawable).
    private(set) var sceneTexture: MTLTexture?

    /// Depth buffer that pairs with sceneTexture for the scene render pass.
    private(set) var depthTexture: MTLTexture?

    /// Receives the blend result before it goes to the display destination.
    private var outputTexture: MTLTexture?

    /// Ring buffer — length × MTLTexture, all sized to match sceneTexture.
    private var queue: [MTLTexture] = []

    // ── Pipeline states ───────────────────────────────────────────────────────

    private var blendPipeline: MTLRenderPipelineState?  // scene + feedback → output
    private var blitPipeline:  MTLRenderPipelineState?  // texture → arbitrary dest

    // ── Playback state ────────────────────────────────────────────────────────

    /// Total rendered-frame counter; drives the modulo check.
    private var frameCounter: Int  = 0

    /// Next slot to write in the ring buffer.
    private var writeIndex:   Int  = 0

    /// True once the ring buffer has been filled once (priming complete).
    private(set) var isFull:  Bool = false

    private var currentWidth:  Int = 0
    private var currentHeight: Int = 0

    // MARK: - Init

    init(device: MTLDevice) {
        self.device = device
        buildPipelines()
        print("[DEBUG] FeedbackProcessor: initialized")
    }

    // MARK: - Pipeline setup

    private func buildPipelines() {
        guard let library = try? device.makeDefaultLibrary(bundle: Bundle.module) else {
            print("[DEBUG] FeedbackProcessor: makeDefaultLibrary failed")
            return
        }
        guard let vertFn  = library.makeFunction(name: "feedback_vertex"),
              let blendFn = library.makeFunction(name: "feedback_blend_fragment"),
              let blitFn  = library.makeFunction(name: "feedback_blit_fragment") else {
            print("[DEBUG] FeedbackProcessor: shader functions not found")
            return
        }

        // Blend pipeline — no depth attachment (fullscreen quad pass)
        let blendDesc = MTLRenderPipelineDescriptor()
        blendDesc.label                             = "FeedbackBlend"
        blendDesc.vertexFunction                    = vertFn
        blendDesc.fragmentFunction                  = blendFn
        blendDesc.colorAttachments[0].pixelFormat   = .bgra8Unorm

        // Blit pipeline — same vertex shader, pass-through fragment
        let blitDesc = MTLRenderPipelineDescriptor()
        blitDesc.label                             = "FeedbackBlit"
        blitDesc.vertexFunction                    = vertFn
        blitDesc.fragmentFunction                  = blitFn
        blitDesc.colorAttachments[0].pixelFormat   = .bgra8Unorm

        do {
            blendPipeline = try device.makeRenderPipelineState(descriptor: blendDesc)
            blitPipeline  = try device.makeRenderPipelineState(descriptor: blitDesc)
            print("[DEBUG] FeedbackProcessor: pipelines created")
        } catch {
            print("[DEBUG] FeedbackProcessor: pipeline creation failed — "
                + error.localizedDescription)
        }
    }

    // MARK: - Resize

    /// Rebuilds all textures to match the new drawable size.
    /// Also rebuilds the queue if `length` changed.
    /// Automatically resets playback state — the queue must re-prime.
    func resize(width: Int, height: Int, length: Int) {
        guard width > 0, height > 0, length > 0 else { return }
        let sizeChanged   = width != currentWidth || height != currentHeight
        let lengthChanged = queue.count != length
        guard sizeChanged || lengthChanged else { return }

        currentWidth  = width
        currentHeight = height

        // Color texture: render target + shader readable (for blend input)
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width, height: height,
            mipmapped: false)
        colorDesc.usage       = [.renderTarget, .shaderRead]
        colorDesc.storageMode = .private

        sceneTexture  = device.makeTexture(descriptor: colorDesc)
        outputTexture = device.makeTexture(descriptor: colorDesc)

        // Depth texture: render target only
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float,
            width: width, height: height,
            mipmapped: false)
        depthDesc.usage       = .renderTarget
        depthDesc.storageMode = .private
        depthTexture = device.makeTexture(descriptor: depthDesc)

        buildQueue(length: length, colorDesc: colorDesc)
        reset()

        print("[DEBUG] FeedbackProcessor: resized \(width)×\(height) length=\(length)"
            + (sceneTexture != nil ? " OK" : " FAILED"))
    }

    // MARK: - Reset

    /// Clears playback state so the queue re-primes from scratch.
    /// Call this before playback starts or export begins.
    func reset() {
        frameCounter = 0
        writeIndex   = 0
        isFull       = false
        print("[DEBUG] FeedbackProcessor: reset")
    }

    // MARK: - Per-frame process

    /// Called each frame after the scene has been rendered into `sceneTexture`.
    /// Runs the feedback algorithm and blits the final result to `dest`.
    ///
    /// - Parameters:
    ///   - commandBuffer: The in-flight command buffer for this frame.
    ///   - dest:          Destination texture — drawable.texture for live view,
    ///                    colorTex for export.
    ///   - settings:      Current feedback parameters.
    func process(commandBuffer: MTLCommandBuffer,
                 dest:          MTLTexture,
                 settings:      FeedbackSettings) {

        guard settings.isEnabled, let scene = sceneTexture else {
            // Feedback disabled or textures not ready: straight blit to dest
            if let scene = sceneTexture {
                blitToTexture(commandBuffer: commandBuffer, source: scene, dest: dest)
            }
            return
        }

        // Rebuild queue if length changed (safe here — queue is independent of sceneTexture)
        if queue.count != settings.length {
            let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: currentWidth, height: currentHeight,
                mipmapped: false)
            colorDesc.usage       = [.renderTarget, .shaderRead]
            colorDesc.storageMode = .private
            buildQueue(length: settings.length, colorDesc: colorDesc)
            reset()
        }

        guard !queue.isEmpty else {
            blitToTexture(commandBuffer: commandBuffer, source: scene, dest: dest)
            return
        }

        // Only process on every Nth rendered frame
        frameCounter += 1
        let isTick = (frameCounter % max(1, settings.interval) == 0)

        guard isTick else {
            // Non-tick frame: persist the last blended output so there is no
            // flash between ticks.  Fall back to the raw scene while priming.
            if isFull, let output = outputTexture {
                blitToTexture(commandBuffer: commandBuffer, source: output, dest: dest)
            } else {
                blitToTexture(commandBuffer: commandBuffer, source: scene, dest: dest)
            }
            return
        }

        if isFull, let output = outputTexture {
            // ── Active: blend scene with oldest queue slot ────────────────────
            runBlendPass(commandBuffer: commandBuffer,
                         sceneTex:     scene,
                         feedbackTex:  queue[writeIndex],
                         outputTex:    output,
                         decay:        settings.decay)

            // Replace oldest slot with the blended result
            copyTexture(commandBuffer: commandBuffer, from: output, to: queue[writeIndex])

            // Display the blended output
            blitToTexture(commandBuffer: commandBuffer, source: output, dest: dest)

        } else {
            // ── Priming: fill queue with raw scene frames ─────────────────────
            copyTexture(commandBuffer: commandBuffer, from: scene, to: queue[writeIndex])

            // Display scene unchanged during priming
            blitToTexture(commandBuffer: commandBuffer, source: scene, dest: dest)
        }

        // Advance write index; set isFull on first wrap-around
        writeIndex = (writeIndex + 1) % queue.count
        if !isFull && writeIndex == 0 {
            isFull = true
            print("[DEBUG] FeedbackProcessor: queue primed — feedback active")
        }
    }

    // MARK: - Passthrough (paused / stopped)

    /// Blits the most recent visible frame to `dest` without touching the queue.
    /// Call this when the timeline is paused or has reached the end so the last
    /// feedback output (or raw scene while priming) stays on screen.
    func blitLastOutput(commandBuffer: MTLCommandBuffer, dest: MTLTexture) {
        if isFull, let output = outputTexture {
            // Feedback active: keep the last blended result visible.
            blitToTexture(commandBuffer: commandBuffer, source: output, dest: dest)
        } else if let scene = sceneTexture {
            // Still priming: show the raw scene.
            blitToTexture(commandBuffer: commandBuffer, source: scene, dest: dest)
        }
    }

    // MARK: - Private Metal helpers

    private func runBlendPass(commandBuffer: MTLCommandBuffer,
                               sceneTex:     MTLTexture,
                               feedbackTex:  MTLTexture,
                               outputTex:    MTLTexture,
                               decay:        Float) {
        guard let pipeline = blendPipeline else { return }

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture     = outputTex
        passDesc.colorAttachments[0].loadAction  = .dontCare
        passDesc.colorAttachments[0].storeAction = .store

        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(sceneTex,    index: 0)
        enc.setFragmentTexture(feedbackTex, index: 1)
        var d = decay
        enc.setFragmentBytes(&d, length: MemoryLayout<Float>.stride, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }

    private func blitToTexture(commandBuffer: MTLCommandBuffer,
                                source: MTLTexture,
                                dest:   MTLTexture) {
        guard let pipeline = blitPipeline else { return }

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture     = dest
        passDesc.colorAttachments[0].loadAction  = .dontCare
        passDesc.colorAttachments[0].storeAction = .store

        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(source, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }

    private func copyTexture(commandBuffer: MTLCommandBuffer,
                              from source: MTLTexture,
                              to   dest:   MTLTexture) {
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.copy(from:              source,
                  sourceSlice:       0, sourceLevel:      0,
                  sourceOrigin:      MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize:        MTLSize(width: source.width, height: source.height, depth: 1),
                  to:                dest,
                  destinationSlice:  0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
    }

    private func buildQueue(length: Int, colorDesc: MTLTextureDescriptor) {
        queue = (0..<length).compactMap { _ in device.makeTexture(descriptor: colorDesc) }
        if queue.count != length {
            print("[DEBUG] FeedbackProcessor: queue allocation partial — got \(queue.count)/\(length)")
        }
    }
}
