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

/// Uniform block passed to the feedback blend shader.
/// Layout must match `struct FeedbackUniforms` in FeedbackShaders.metal exactly.
struct FeedbackUniforms {
    var decay:      Float   // blend weight 0–1
    var blendMode:  UInt32  // BlendMode.rawValue
    var swapLayers: UInt32  // 0 = scene on top, 1 = feedback on top
    var excludeBackground: UInt32  // 1 = foreground-only premultiplied (bg drawn fresh behind)
}

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
    private var blitPipeline:  MTLRenderPipelineState?  // texture → dest (overwrite)
    /// Premultiplied source-over variant of the blit, used when the environment is
    /// excluded from feedback so the foreground/trail composites over the freshly
    /// drawn skybox already on the destination.
    private var blitOverPipeline: MTLRenderPipelineState?

    // ── Playback state ────────────────────────────────────────────────────────

    /// Total rendered-frame counter; drives the modulo check.
    private var frameCounter: Int  = 0

    /// Next slot to write in the ring buffer.
    private var writeIndex:   Int  = 0

    /// True once the ring buffer has been filled once (priming complete).
    private(set) var isFull:  Bool = false

    /// True once the first active blend pass has written to outputTexture.
    /// Guards against blitting uninitialized GPU memory on non-tick frames
    /// between isFull becoming true and the first actual blend pass running.
    private var hasOutput: Bool = false

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

        // Premultiplied source-over blit (composites over the destination's contents).
        let overDesc = MTLRenderPipelineDescriptor()
        overDesc.label                             = "FeedbackBlitOver"
        overDesc.vertexFunction                    = vertFn
        overDesc.fragmentFunction                  = blitFn
        let oca = overDesc.colorAttachments[0]!
        oca.pixelFormat                 = .bgra8Unorm
        oca.isBlendingEnabled           = true
        oca.rgbBlendOperation           = .add
        oca.alphaBlendOperation         = .add
        oca.sourceRGBBlendFactor        = .one                  // premultiplied
        oca.destinationRGBBlendFactor   = .oneMinusSourceAlpha
        oca.sourceAlphaBlendFactor      = .one
        oca.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            blendPipeline    = try device.makeRenderPipelineState(descriptor: blendDesc)
            blitPipeline     = try device.makeRenderPipelineState(descriptor: blitDesc)
            blitOverPipeline = try device.makeRenderPipelineState(descriptor: overDesc)
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

        // Depth texture: render target + shader-readable so the fog volume pass can
        // sample scene depth when feedback is active (fog + feedback coexistence).
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float,
            width: width, height: height,
            mipmapped: false)
        depthDesc.usage       = [.renderTarget, .shaderRead]
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
        hasOutput    = false
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
    /// `excludeBackground`: when true the scene texture holds the foreground only
    /// (premultiplied, transparent where empty) and the caller has already drawn the
    /// skybox onto `dest`, so every display blit composites over it (source-over).
    func process(commandBuffer: MTLCommandBuffer,
                 dest:          MTLTexture,
                 settings:      FeedbackSettings,
                 excludeBackground: Bool = false) {

        guard settings.isEnabled, let scene = sceneTexture else {
            // Feedback disabled or textures not ready: straight blit to dest
            if let scene = sceneTexture {
                blitToTexture(commandBuffer: commandBuffer, source: scene, dest: dest, over: excludeBackground)
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
            blitToTexture(commandBuffer: commandBuffer, source: scene, dest: dest, over: excludeBackground)
            return
        }

        // Only process on every Nth rendered frame
        frameCounter += 1
        let isTick = (frameCounter % max(1, settings.interval) == 0)

        guard isTick else {
            // Non-tick frame: persist the last blended output so there is no
            // flash between ticks.  Fall back to the raw scene while priming or
            // before the first blend pass has written to outputTexture.
            if isFull && hasOutput, let output = outputTexture {
                blitToTexture(commandBuffer: commandBuffer, source: output, dest: dest, over: excludeBackground)
            } else {
                blitToTexture(commandBuffer: commandBuffer, source: scene, dest: dest, over: excludeBackground)
            }
            return
        }

        if isFull, let output = outputTexture {
            // ── Active: blend scene with oldest queue slot ────────────────────
            runBlendPass(commandBuffer: commandBuffer,
                         sceneTex:     scene,
                         feedbackTex:  queue[writeIndex],
                         outputTex:    output,
                         settings:     settings,
                         excludeBackground: excludeBackground)

            hasOutput = true

            // Replace oldest slot with the blended result
            copyTexture(commandBuffer: commandBuffer, from: output, to: queue[writeIndex])

            // Display the blended output
            blitToTexture(commandBuffer: commandBuffer, source: output, dest: dest, over: excludeBackground)

        } else {
            // ── Priming: fill queue with raw scene frames ─────────────────────
            copyTexture(commandBuffer: commandBuffer, from: scene, to: queue[writeIndex])

            // Display scene unchanged during priming
            blitToTexture(commandBuffer: commandBuffer, source: scene, dest: dest, over: excludeBackground)
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
    func blitLastOutput(commandBuffer: MTLCommandBuffer, dest: MTLTexture,
                        excludeBackground: Bool = false) {
        if isFull && hasOutput, let output = outputTexture {
            // Feedback active and at least one blend has run: keep the last blended result.
            blitToTexture(commandBuffer: commandBuffer, source: output, dest: dest, over: excludeBackground)
        } else if let scene = sceneTexture {
            // Still priming, or isFull but first blend not yet run: show the raw scene.
            blitToTexture(commandBuffer: commandBuffer, source: scene, dest: dest, over: excludeBackground)
        }
    }

    // MARK: - Private Metal helpers

    private func runBlendPass(commandBuffer: MTLCommandBuffer,
                               sceneTex:     MTLTexture,
                               feedbackTex:  MTLTexture,
                               outputTex:    MTLTexture,
                               settings:     FeedbackSettings,
                               excludeBackground: Bool) {
        guard let pipeline = blendPipeline else { return }

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture     = outputTex
        passDesc.colorAttachments[0].loadAction  = .dontCare
        passDesc.colorAttachments[0].storeAction = .store

        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(sceneTex,    index: 0)
        enc.setFragmentTexture(feedbackTex, index: 1)
        var u = FeedbackUniforms(
            decay:      settings.decay,
            blendMode:  UInt32(settings.blendMode.rawValue),
            swapLayers: settings.swapLayers ? 1 : 0,
            excludeBackground: excludeBackground ? 1 : 0
        )
        enc.setFragmentBytes(&u, length: MemoryLayout<FeedbackUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }

    /// `over`: composite the source over the destination (premultiplied source-over,
    /// preserving what's already there) instead of overwriting it.
    private func blitToTexture(commandBuffer: MTLCommandBuffer,
                                source: MTLTexture,
                                dest:   MTLTexture,
                                over:   Bool = false) {
        guard let pipeline = over ? blitOverPipeline : blitPipeline else { return }

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture     = dest
        passDesc.colorAttachments[0].loadAction  = over ? .load : .dontCare
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
