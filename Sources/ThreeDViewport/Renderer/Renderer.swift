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

    var isWireframe:   Bool = false
    var isColorMode:   Bool = false   // false = greyscale (default)
    var showAxesGizmo: Bool = false

    // Gizmo pipeline (no depth attachment, alpha-blended 2-D overlay)
    private var gizmoPipelineState: MTLRenderPipelineState?

    // Laser beam pipeline (additive RGB blend, depth test without write)
    private var laserBeamPipelineState: MTLRenderPipelineState?
    private var laserBeamDepthState:    MTLDepthStencilState?

    // Laser hit effect pipeline (additive, same depth state as laser beams)
    private var laserHitPipelineState:  MTLRenderPipelineState?

    // Spark particle pipeline (additive, instanced billboards)
    private var sparkPipelineState:     MTLRenderPipelineState?

    // MARK: - Feedback (optional — set by ViewportView after init)

    var feedbackProcessor: FeedbackProcessor?
    var feedbackSettings:  FeedbackSettings?

    // MARK: - Color grade (optional — set by ViewportView after init)

    var colorGradeSettings:    ColorGradeSettings?
    private var colorGradePipeline: MTLRenderPipelineState?
    private var gradeTexture:  MTLTexture?   // intermediate; rebuilt on size change

    // MARK: - Laser hit effect

    private var laserHitSystem:   LaserHitSystem   = LaserHitSystem()
    private var hitEffectTime:    Float             = 0
    private var lastDrawWallTime: CFAbsoluteTime    = 0

    private var lastAnimatedTime: Double = -1.0
    /// currentTime at end of previous frame — detects manual scrub while paused.
    private var lastRenderedTime: Double = -1.0
    /// isPlaying state at end of previous frame — lets us distinguish "just stopped"
    /// (natural end of playback) from "scrubbed while paused".
    private var lastWasPlaying:   Bool   = false

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

        // ── Axes gizmo pipeline ───────────────────────────────────────────────
        guard let gizmoVertFn = library.makeFunction(name: "gizmo_vertex"),
              let gizmoFragFn = library.makeFunction(name: "gizmo_fragment") else {
            print("[DEBUG] Renderer: gizmo shaders not found")
            return
        }
        let gizmoDesc = MTLRenderPipelineDescriptor()
        gizmoDesc.label          = "Gizmo"
        gizmoDesc.vertexFunction   = gizmoVertFn
        gizmoDesc.fragmentFunction = gizmoFragFn
        // Alpha-blend so axis lines composite cleanly over the scene
        let gizmoCA = gizmoDesc.colorAttachments[0]!
        gizmoCA.pixelFormat                 = .bgra8Unorm
        gizmoCA.isBlendingEnabled           = true
        gizmoCA.sourceRGBBlendFactor        = .sourceAlpha
        gizmoCA.destinationRGBBlendFactor   = .oneMinusSourceAlpha
        gizmoCA.sourceAlphaBlendFactor      = .one
        gizmoCA.destinationAlphaBlendFactor = .zero
        // No depth attachment — gizmo always renders on top
        do {
            gizmoPipelineState = try device.makeRenderPipelineState(descriptor: gizmoDesc)
            print("[DEBUG] Renderer: gizmo pipeline created")
        } catch {
            print("[DEBUG] Renderer: gizmo pipeline failed — " + error.localizedDescription)
        }

        // ── Laser beam billboard pipeline ─────────────────────────────────────
        guard let laserVertFn = library.makeFunction(name: "laser_beam_vertex"),
              let laserFragFn = library.makeFunction(name: "laser_beam_fragment") else {
            print("[DEBUG] Renderer: laser beam shaders not found")
            return
        }
        let laserDesc = MTLRenderPipelineDescriptor()
        laserDesc.label                           = "LaserBeam"
        laserDesc.vertexFunction                  = laserVertFn
        laserDesc.fragmentFunction                = laserFragFn
        laserDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        laserDesc.depthAttachmentPixelFormat      = .depth32Float
        // Additive RGB blend — beam brightens the scene; destination alpha preserved
        let laserCA = laserDesc.colorAttachments[0]!
        laserCA.isBlendingEnabled           = true
        laserCA.sourceRGBBlendFactor        = .one
        laserCA.destinationRGBBlendFactor   = .one
        laserCA.rgbBlendOperation           = .add
        laserCA.sourceAlphaBlendFactor      = .zero     // preserve dest alpha
        laserCA.destinationAlphaBlendFactor = .one
        laserCA.alphaBlendOperation         = .add
        do {
            laserBeamPipelineState = try device.makeRenderPipelineState(descriptor: laserDesc)
            print("[DEBUG] Renderer: laser beam pipeline created")
        } catch {
            print("[DEBUG] Renderer: laser beam pipeline failed — " + error.localizedDescription)
        }

        let laserDepthDesc = MTLDepthStencilDescriptor()
        laserDepthDesc.depthCompareFunction = .lessEqual
        laserDepthDesc.isDepthWriteEnabled  = false   // read-only depth test
        laserBeamDepthState = device.makeDepthStencilState(descriptor: laserDepthDesc)

        // ── Laser hit effect pipeline ─────────────────────────────────────────
        guard let hitVertFn = library.makeFunction(name: "laser_hit_vertex"),
              let hitFragFn = library.makeFunction(name: "laser_hit_fragment") else {
            print("[DEBUG] Renderer: laser hit shaders not found")
            return
        }
        let hitDesc = MTLRenderPipelineDescriptor()
        hitDesc.label          = "LaserHit"
        hitDesc.vertexFunction   = hitVertFn
        hitDesc.fragmentFunction = hitFragFn
        hitDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        hitDesc.depthAttachmentPixelFormat      = .depth32Float
        let hitCA = hitDesc.colorAttachments[0]!
        hitCA.isBlendingEnabled           = true
        hitCA.sourceRGBBlendFactor        = .one
        hitCA.destinationRGBBlendFactor   = .one
        hitCA.rgbBlendOperation           = .add
        hitCA.sourceAlphaBlendFactor      = .zero
        hitCA.destinationAlphaBlendFactor = .one
        hitCA.alphaBlendOperation         = .add
        do {
            laserHitPipelineState = try device.makeRenderPipelineState(descriptor: hitDesc)
            print("[DEBUG] Renderer: laser hit pipeline created")
        } catch {
            print("[DEBUG] Renderer: laser hit pipeline failed — " + error.localizedDescription)
        }

        // ── Spark particle pipeline ───────────────────────────────────────────
        guard let sparkVertFn = library.makeFunction(name: "spark_vertex"),
              let sparkFragFn = library.makeFunction(name: "spark_fragment") else {
            print("[DEBUG] Renderer: spark shaders not found")
            return
        }
        let sparkDesc = MTLRenderPipelineDescriptor()
        sparkDesc.label          = "Spark"
        sparkDesc.vertexFunction   = sparkVertFn
        sparkDesc.fragmentFunction = sparkFragFn
        sparkDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        sparkDesc.depthAttachmentPixelFormat      = .depth32Float
        let sparkCA = sparkDesc.colorAttachments[0]!
        sparkCA.isBlendingEnabled           = true
        sparkCA.sourceRGBBlendFactor        = .one
        sparkCA.destinationRGBBlendFactor   = .one
        sparkCA.rgbBlendOperation           = .add
        sparkCA.sourceAlphaBlendFactor      = .zero
        sparkCA.destinationAlphaBlendFactor = .one
        sparkCA.alphaBlendOperation         = .add
        do {
            sparkPipelineState = try device.makeRenderPipelineState(descriptor: sparkDesc)
            print("[DEBUG] Renderer: spark pipeline created")
        } catch {
            print("[DEBUG] Renderer: spark pipeline failed — " + error.localizedDescription)
        }

        // ── Color grade pipeline (fullscreen pass, no depth) ──────────────────
        guard let gradeVertFn = library.makeFunction(name: "color_grade_vertex"),
              let gradeFragFn = library.makeFunction(name: "color_grade_fragment") else {
            print("[DEBUG] Renderer: color_grade shaders not found")
            return
        }
        let gradeDesc = MTLRenderPipelineDescriptor()
        gradeDesc.label                             = "ColorGrade"
        gradeDesc.vertexFunction                    = gradeVertFn
        gradeDesc.fragmentFunction                  = gradeFragFn
        gradeDesc.colorAttachments[0].pixelFormat   = .bgra8Unorm
        // No depth attachment, no blending — every pixel is overwritten
        do {
            colorGradePipeline = try device.makeRenderPipelineState(descriptor: gradeDesc)
            print("[DEBUG] Renderer: color grade pipeline created")
        } catch {
            print("[DEBUG] Renderer: color grade pipeline failed — " + error.localizedDescription)
        }
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
        // Rebuild grade intermediate texture at the new drawable size.
        rebuildGradeTexture(width: Int(size.width), height: Int(size.height))
    }

    private func rebuildGradeTexture(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage       = [.shaderRead, .renderTarget]
        desc.storageMode = .private
        gradeTexture = device.makeTexture(descriptor: desc)
        print("[DEBUG] Renderer: gradeTexture rebuilt \(width)×\(height)")
    }

    func draw(in view: MTKView) {
        // Wall-clock dt for hit effect animation (independent of timeline)
        let now = CFAbsoluteTimeGetCurrent()
        let dt  = lastDrawWallTime > 0 ? Float(now - lastDrawWallTime) : (1.0 / 60.0)
        lastDrawWallTime = now
        hitEffectTime += dt

        timeline.tick()

        // Reset feedback only when the user manually scrubs while already paused.
        // "Just stopped" (isPlaying flipped to false this frame) must NOT reset —
        // that would wipe the last feedback frame at the natural end of playback.
        let justStopped = lastWasPlaying && !timeline.isPlaying
        if !timeline.isPlaying && !justStopped && timeline.currentTime != lastRenderedTime {
            feedbackProcessor?.reset()
        }
        lastWasPlaying   = timeline.isPlaying
        lastRenderedTime = timeline.currentTime

        if timeline.currentTime != lastAnimatedTime {
            applyAnimation()
            lastAnimatedTime = timeline.currentTime
        }

        view.clearColor = backgroundConfig.clearColor

        guard let pipeline      = pipelineState else { return }
        guard let drawable      = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        // Lazy-init: resize feedback textures on the first draw (or after the
        // feedbackProcessor is wired in) if they haven't been created yet.
        // mtkView(_:drawableSizeWillChange:) may fire before feedbackProcessor
        // is assigned, leaving sceneTexture nil — this covers that race.
        if let fp = feedbackProcessor, fp.sceneTexture == nil {
            let fw = min(Int(view.drawableSize.width),  1920)
            let fh = min(Int(view.drawableSize.height), 1080)
            fp.resize(width: fw, height: fh, length: feedbackSettings?.length ?? 10)
        }

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
            // alpha=0 marks cleared pixels as background so the feedback blend
            // shader can use scene.a as a content mask (geometry writes alpha=1).
            let bc = backgroundConfig.clearColor
            desc.colorAttachments[0].clearColor  = MTLClearColor(
                red: bc.red, green: bc.green, blue: bc.blue, alpha: 0.0)
            desc.depthAttachment.texture         = depthTex
            desc.depthAttachment.loadAction      = .clear
            // Store depth so the excluded-laser post-pass can depth-test against it.
            desc.depthAttachment.storeAction     = .store
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
        // Do NOT early-return here: even an empty scene must go through the
        // feedback path so fp.process ticks every frame and the drawable gets
        // content when feedback is rendering to sceneTexture.
        let visibleObjects = sceneManager.objects.filter { $0.isVisible }

        if !visibleObjects.isEmpty {
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
        }

        // ── Laser hit detection + particle update ─────────────────────────────
        let screenSize = SIMD2<Float>(Float(view.drawableSize.width),
                                      Float(view.drawableSize.height))
        let visibleForHits = sceneManager.objects.filter { $0.isVisible }
        laserHitSystem.updateHits(lights: lightManager.lights, objects: visibleForHits)
        laserHitSystem.updateParticles(dt: dt)
        let sparkGPUData = laserHitSystem.buildSparkGPUData()

        // ── Laser beam visuals (included in feedback, or all when feedback is off) ─
        drawLaserBeamsInEncoder(encoder, screenSize: screenSize,
                                excludedOnly: false)
        drawLaserHitsInEncoder(encoder, screenSize: screenSize,
                               hitEffectTime: hitEffectTime, excludedOnly: false)
        // When feedback is not active "excludeBeamFromFeedback" is meaningless —
        // draw those beams, their hits, and all sparks here too so they always appear.
        if !feedbackActive {
            drawLaserBeamsInEncoder(encoder, screenSize: screenSize,
                                    excludedOnly: true)
            drawLaserHitsInEncoder(encoder, screenSize: screenSize,
                                   hitEffectTime: hitEffectTime, excludedOnly: true)
            drawSparksInEncoder(encoder, sparkGPUData: sparkGPUData)
        }

        encoder.endEncoding()

        // Feedback composite + blit to drawable.
        // Only run the queue/blend logic while the timeline is playing so the
        // feedback freezes (and the raw scene stays visible) when paused or
        // when the end of the animation is reached.
        if feedbackActive, let fp = feedbackProcessor, let fs = feedbackSettings {
            if timeline.isPlaying {
                fp.process(commandBuffer: commandBuffer,
                           dest:          drawable.texture,
                           settings:      fs)
            } else {
                fp.blitLastOutput(commandBuffer: commandBuffer, dest: drawable.texture)
            }
        }

        // ── Excluded laser beams + their hit effects + all sparks ─────────────
        // Drawn after feedback so none of these get feedback trails.
        if feedbackActive, let fp = feedbackProcessor, let depthTex = fp.depthTexture {
            drawExcludedLaserBeams(commandBuffer: commandBuffer,
                                   dest:          drawable.texture,
                                   depthTex:      depthTex,
                                   screenSize:    screenSize,
                                   hitEffectTime: hitEffectTime,
                                   sparkGPUData:  sparkGPUData)
        }

        // Axes gizmo overlay — drawn on top of everything (no depth test).
        if showAxesGizmo {
            drawGizmoPass(commandBuffer: commandBuffer,
                          dest:          drawable.texture,
                          width:         Int(view.drawableSize.width),
                          height:        Int(view.drawableSize.height))
        }

        // ── Color grade (brightness / contrast) — very last pass ─────────────
        if let settings = colorGradeSettings, !settings.isIdentity,
           let gradeTex = gradeTexture {
            if let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.copy(from: drawable.texture, to: gradeTex)
                blit.endEncoding()
            }
            applyColorGrade(commandBuffer: commandBuffer,
                            source: gradeTex,
                            dest:   drawable.texture,
                            settings: settings)
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Color grade helper

    func applyColorGrade(commandBuffer: MTLCommandBuffer,
                         source:        MTLTexture,
                         dest:          MTLTexture,
                         settings:      ColorGradeSettings) {
        guard let pipeline = colorGradePipeline else { return }
        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture     = dest
        passDesc.colorAttachments[0].loadAction  = .dontCare   // every pixel overwritten
        passDesc.colorAttachments[0].storeAction = .store
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setCullMode(.none)
        enc.setFragmentTexture(source, index: 0)
        // z = 1/gamma: precompute reciprocal so the shader avoids per-pixel division.
        // Clamp gamma to avoid division by zero; identity when gamma==1 → z==1.
        let gammaExp = 1.0 / max(settings.gamma, 0.01)
        var params = SIMD3<Float>(settings.brightness, settings.contrast, gammaExp)
        enc.setFragmentBytes(&params, length: MemoryLayout<SIMD3<Float>>.stride, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }

    // MARK: - Axes gizmo

    /// Swift-side vertex struct matching the Metal `GizmoVertex` layout exactly.
    /// float4 position (16 B) + float4 color (16 B) = 32 B, no padding needed.
    private struct GizmoVertex {
        var position: SIMD4<Float>  // xy = NDC, zw = 0,1
        var color:    SIMD4<Float>
    }

    /// Renders a small XYZ orientation gizmo in the bottom-right corner of `dest`.
    func drawGizmoPass(commandBuffer: MTLCommandBuffer,
                        dest: MTLTexture,
                        width: Int, height: Int) {
        guard let pipeline = gizmoPipelineState else { return }

        // Project world X/Y/Z axes through the camera's rotation (no translation).
        // The view matrix upper-left 3×3 maps world dirs to camera screen coords.
        let vm = camera.viewMatrix
        // World axes projected: column index selects the axis (X=0, Y=1, Z=2).
        // vm.columns.n.x = camera-right component; .y = camera-up component.
        let xDir = SIMD2<Float>(vm.columns.0.x, vm.columns.0.y)
        let yDir = SIMD2<Float>(vm.columns.1.x, vm.columns.1.y)
        let zDir = SIMD2<Float>(vm.columns.2.x, vm.columns.2.y)

        // Gizmo metrics (screen pixels → NDC)
        let fw = Float(width); let fh = Float(height)
        let gizmoRadius: Float = 36          // half-size of the gizmo box
        let margin:      Float = 18
        // Centre of gizmo in NDC (bottom-right corner; NDC y=−1 at bottom)
        let cx = 1.0 - (margin + gizmoRadius) / fw * 2
        let cy = -1.0 + (margin + gizmoRadius) / fh * 2
        let scale     = gizmoRadius * 2 / min(fw, fh)  // axis length in NDC
        let thickness = 2.5 / fh                        // line width in NDC

        let axisData: [(SIMD2<Float>, SIMD4<Float>)] = [
            (xDir, SIMD4<Float>(0.95, 0.25, 0.25, 1.0)),  // X — red
            (yDir, SIMD4<Float>(0.25, 0.90, 0.25, 1.0)),  // Y — green
            (zDir, SIMD4<Float>(0.35, 0.55, 1.00, 1.0)),  // Z — blue
        ]

        var verts: [GizmoVertex] = []
        verts.reserveCapacity(axisData.count * 4)

        for (dir, col) in axisData {
            let ndx = dir.x * scale
            let ndy = dir.y * scale
            let ex  = cx + ndx; let ey = cy + ndy
            let len = sqrt(ndx * ndx + ndy * ndy)
            let px: Float = len > 0.0001 ? -ndy / len * thickness : 0
            let py: Float = len > 0.0001 ?  ndx / len * thickness : thickness
            // Four corners of the thin rectangle (triangleStrip order)
            verts.append(GizmoVertex(position: SIMD4<Float>(cx - px, cy - py, 0, 1), color: col))
            verts.append(GizmoVertex(position: SIMD4<Float>(cx + px, cy + py, 0, 1), color: col))
            verts.append(GizmoVertex(position: SIMD4<Float>(ex - px, ey - py, 0, 1), color: col))
            verts.append(GizmoVertex(position: SIMD4<Float>(ex + px, ey + py, 0, 1), color: col))
        }

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture     = dest
        passDesc.colorAttachments[0].loadAction  = .load   // preserve scene content
        passDesc.colorAttachments[0].storeAction = .store

        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return }
        enc.setRenderPipelineState(pipeline)
        verts.withUnsafeBytes { ptr in
            enc.setVertexBytes(ptr.baseAddress!, length: ptr.count, index: 0)
        }
        for i in 0..<axisData.count {
            enc.drawPrimitives(type: .triangleStrip, vertexStart: i * 4, vertexCount: 4)
        }
        enc.endEncoding()
    }

    // MARK: - Laser beam helpers

    /// Draws laser beams into an already-open render command encoder (scene pass).
    /// `excludedOnly` — false: draw beams with `excludeBeamFromFeedback == false`;
    ///                  true:  draw beams with `excludeBeamFromFeedback == true`.
    private func drawLaserBeamsInEncoder(_ encoder:    MTLRenderCommandEncoder,
                                         screenSize:   SIMD2<Float>,
                                         excludedOnly: Bool) {
        guard let pipeline = laserBeamPipelineState else { return }

        // Collect (index, light) pairs so we can look up hit distances by slot.
        let indexedBeams = lightManager.lights.enumerated().filter {
            $0.element.type == .laser && $0.element.isEnabled &&
            $0.element.excludeBeamFromFeedback == excludedOnly
        }
        guard !indexedBeams.isEmpty else { return }

        encoder.setRenderPipelineState(pipeline)
        if let ds = laserBeamDepthState { encoder.setDepthStencilState(ds) }
        encoder.setCullMode(.none)

        let vp = camera.viewProjectionMatrix
        for (slotIndex, laser) in indexedBeams {
            let start = laser.position
            // If the beam is hitting an object, stop it at the surface.
            let effectiveRange = laserHitSystem.hits[slotIndex].map {
                min(laser.range, $0.distance)
            } ?? laser.range
            let end   = start + simd_normalize(laser.direction) * effectiveRange
            var u = LaserBeamUniforms(
                viewProjectionMatrix: vp,
                startWorld: SIMD4<Float>(start, 1),
                endWorld:   SIMD4<Float>(end,   1),
                color:      SIMD4<Float>(laser.color, 1),
                screenSize: screenSize,
                thickness:  max(1.0, laser.beamThickness),
                pad:        0
            )
            encoder.setVertexBytes(&u, length: MemoryLayout<LaserBeamUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }

    /// Draws excluded laser beams + their hit effects + all sparks in a single
    /// post-feedback pass.  Uses the preserved depth texture for occlusion.
    private func drawExcludedLaserBeams(commandBuffer: MTLCommandBuffer,
                                         dest:          MTLTexture,
                                         depthTex:      MTLTexture,
                                         screenSize:    SIMD2<Float>,
                                         hitEffectTime: Float,
                                         sparkGPUData:  [SparkParticleGPU]) {
        let excludedBeams = lightManager.lights.enumerated().filter {
            $0.element.type == .laser && $0.element.isEnabled && $0.element.excludeBeamFromFeedback
        }
        let hasBeams  = !excludedBeams.isEmpty
        let hasHits   = excludedBeams.contains { laserHitSystem.hits[$0.offset] != nil }
        let hasSparks = !sparkGPUData.isEmpty
        guard hasBeams || hasHits || hasSparks else { return }

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture     = dest
        passDesc.colorAttachments[0].loadAction  = .load
        passDesc.colorAttachments[0].storeAction = .store
        passDesc.depthAttachment.texture         = depthTex
        passDesc.depthAttachment.loadAction      = .load
        passDesc.depthAttachment.storeAction     = .dontCare   // read-only

        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return }

        // Beams
        if hasBeams, let pipeline = laserBeamPipelineState {
            enc.setRenderPipelineState(pipeline)
            if let ds = laserBeamDepthState { enc.setDepthStencilState(ds) }
            enc.setCullMode(.none)
            let vp = camera.viewProjectionMatrix
            for (slotIndex, laser) in excludedBeams {
                let start = laser.position
                let effectiveRange = laserHitSystem.hits[slotIndex].map {
                    min(laser.range, $0.distance)
                } ?? laser.range
                let end   = start + simd_normalize(laser.direction) * effectiveRange
                var u = LaserBeamUniforms(
                    viewProjectionMatrix: vp,
                    startWorld: SIMD4<Float>(start, 1),
                    endWorld:   SIMD4<Float>(end,   1),
                    color:      SIMD4<Float>(laser.color, 1),
                    screenSize: screenSize,
                    thickness:  max(1.0, laser.beamThickness),
                    pad:        0
                )
                enc.setVertexBytes(&u, length: MemoryLayout<LaserBeamUniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }

        // Hit effects for excluded beams
        drawLaserHitsInEncoder(enc, screenSize: screenSize,
                               hitEffectTime: hitEffectTime, excludedOnly: true)

        // All sparks (never get feedback trails regardless of source laser)
        drawSparksInEncoder(enc, sparkGPUData: sparkGPUData)

        enc.endEncoding()
    }

    /// Draws hit flare billboards into an already-open encoder.
    /// `excludedOnly` mirrors the same flag on the associated laser light.
    private func drawLaserHitsInEncoder(_ encoder:      MTLRenderCommandEncoder,
                                         screenSize:     SIMD2<Float>,
                                         hitEffectTime:  Float,
                                         excludedOnly:   Bool) {
        guard let pipeline = laserHitPipelineState else { return }
        let vp = camera.viewProjectionMatrix
        var pipelineSet = false

        for (i, laser) in lightManager.lights.enumerated() {
            guard laser.type == .laser, laser.isEnabled,
                  laser.excludeBeamFromFeedback == excludedOnly,
                  let hit = laserHitSystem.hits[i] else { continue }

            if !pipelineSet {
                encoder.setRenderPipelineState(pipeline)
                if let ds = laserBeamDepthState { encoder.setDepthStencilState(ds) }
                encoder.setCullMode(.none)
                pipelineSet = true
            }

            var u = LaserHitUniforms(
                viewProjectionMatrix: vp,
                hitPoint:   SIMD4<Float>(hit.point, 1),
                color:      SIMD4<Float>(hit.color,  1),
                screenSize: screenSize,
                hitRadius:  60.0,
                time:       hitEffectTime
            )
            encoder.setVertexBytes(&u, length: MemoryLayout<LaserHitUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }

    /// Draws all live spark particles as instanced camera-facing billboards.
    private func drawSparksInEncoder(_ encoder:    MTLRenderCommandEncoder,
                                      sparkGPUData: [SparkParticleGPU]) {
        guard let pipeline = sparkPipelineState, !sparkGPUData.isEmpty else { return }

        // Spark data is too large for setVertexBytes (>4 KB at 256 particles).
        // Create a transient shared buffer for this frame.
        let byteCount = sparkGPUData.count * MemoryLayout<SparkParticleGPU>.stride
        guard let sparkBuf = device.makeBuffer(bytes: sparkGPUData,
                                               length: byteCount,
                                               options: .storageModeShared) else { return }

        encoder.setRenderPipelineState(pipeline)
        if let ds = laserBeamDepthState { encoder.setDepthStencilState(ds) }
        encoder.setCullMode(.none)

        var su = SparkUniforms(
            viewProjectionMatrix: camera.viewProjectionMatrix,
            cameraRight: SIMD4<Float>(camera.rightVector, 0),
            cameraUp:    SIMD4<Float>(camera.upVector,    0)
        )
        encoder.setVertexBuffer(sparkBuf, offset: 0, index: 0)
        encoder.setVertexBytes(&su, length: MemoryLayout<SparkUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0,
                               vertexCount: 4, instanceCount: sparkGPUData.count)
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

    /// Forces `applyAnimation()` to run on the very next draw call, regardless of
    /// whether `currentTime` has changed.  Call this after restoring keyframe tracks
    /// from a project file — without it, the t=0 pose may not be applied because
    /// `lastAnimatedTime` already equals `currentTime` (both are 0).
    func invalidateAnimationCache() {
        lastAnimatedTime = -1.0
        print("[DEBUG] Renderer: animation cache invalidated — will re-evaluate on next draw")
    }

    private func applyAnimation() {
        // ── Object transforms ─────────────────────────────────────────────────
        for object in sceneManager.objects {
            guard let track = object.keyframeTrack,
                  !track.keyframes.isEmpty else { continue }
            if let delta = track.evaluate(at: timeline.currentTime) {
                object.transform = object.baseTransform * delta
            }
        }

        // ── Camera ────────────────────────────────────────────────────────────
        if let camTrack = camera.keyframeTrack, !camTrack.keyframes.isEmpty {
            if let state = camTrack.evaluate(at: timeline.currentTime) {
                camera.yaw      = state.yaw
                camera.pitch    = state.pitch
                camera.distance = state.distance
                camera.target   = state.target
            }
        }

        // ── Lights ────────────────────────────────────────────────────────────
        for i in 0..<lightManager.lights.count {
            guard i < lightManager.keyframeTracks.count,
                  let track = lightManager.keyframeTracks[i],
                  !track.keyframes.isEmpty else { continue }
            if let state = track.evaluate(at: timeline.currentTime) {
                lightManager.lights[i].intensity     = state.intensity
                lightManager.lights[i].color         = state.color
                lightManager.lights[i].direction     = state.direction
                lightManager.lights[i].position      = state.position
                lightManager.lights[i].range         = state.range
                lightManager.lights[i].beamThickness = state.beamThickness
            }
        }
    }
}
