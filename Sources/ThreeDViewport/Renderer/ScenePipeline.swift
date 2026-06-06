import Metal
import simd

// Per-frame scene + camera data a shared pass needs, resolved by the calling
// driver (so deterministic-export vs wall-clock-live, and scene-vs-director
// camera, stay driver concerns).  Grows one field group per migration phase.
struct SceneRenderContext {
    // Camera (already resolved: director-or-scene live, export camera on export)
    var viewProjection:     matrix_float4x4
    var eyePosition:        SIMD3<Float>

    // Background / skybox
    var background:         BackgroundConfig
    var backgroundEquirect: MTLTexture?      // dedicated bg HDR, else nil
    var ibl:                IBL?
    var colorMode:          RenderColorMode
    var dummyEquirect:      MTLTexture?      // 1×1 fallback for the skybox equirect slot

    // Timing (resolved by the driver: live timeline vs deterministic export)
    var time:               Double
    var playing:            Bool

    // Fog volume
    var fog:                FogSettings?     // nil / disabled = no fog pass
}

// Shared compositing core.  Owns the effect pipeline states that BOTH the live
// `Renderer` and the offline `VideoExporter` use, built ONCE here so preview and
// export can never drift.  See RENDER_PIPELINE_REFACTOR.md.
//
// Phase 0: this owns only the pipeline-STATE *construction*.  The per-pass draw
// encoding still lives in the two drivers (they read these states via thin
// handles) and migrates here one pass at a time in later phases.
//
// All color attachments are .bgra8Unorm and all depth attachments .depth32Float,
// matching both drivers' targets, so a single shared state set is valid for both.
// A missing shader leaves that one state nil (the drivers already nil-check every
// state before drawing); it never aborts the rest of the set.
final class ScenePipeline {

    // Background gradient + environment skybox
    let backgroundPipelineState: MTLRenderPipelineState?
    let backgroundDepthState:    MTLDepthStencilState?
    let skyboxPipelineState:     MTLRenderPipelineState?

    // Laser beam / hit / spark (all additive RGB blend)
    let laserBeamPipelineState:  MTLRenderPipelineState?
    let laserBeamDepthState:     MTLDepthStencilState?
    let laserHitPipelineState:   MTLRenderPipelineState?
    let sparkPipelineState:      MTLRenderPipelineState?

    // Weather particles + fog volume
    let particleFXPipelineState: MTLRenderPipelineState?
    let fogVolumePipelineState:  MTLRenderPipelineState?

    // Color grade (fullscreen post, no depth, no blend)
    let colorGradePipelineState: MTLRenderPipelineState?

    init(device: MTLDevice, library: MTLLibrary) {

        var background: MTLRenderPipelineState?
        var backgroundDepth: MTLDepthStencilState?
        var skybox:     MTLRenderPipelineState?
        var laserBeam:  MTLRenderPipelineState?
        var laserBeamDepth: MTLDepthStencilState?
        var laserHit:   MTLRenderPipelineState?
        var spark:      MTLRenderPipelineState?
        var particleFX: MTLRenderPipelineState?
        var fogVolume:  MTLRenderPipelineState?
        var colorGrade: MTLRenderPipelineState?

        // ── Background gradient pipeline ──────────────────────────────────────
        if let bgVertFn = library.makeFunction(name: "background_vertex"),
           let bgFragFn = library.makeFunction(name: "background_fragment") {
            let bgDesc = MTLRenderPipelineDescriptor()
            bgDesc.vertexFunction   = bgVertFn
            bgDesc.fragmentFunction = bgFragFn
            bgDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
            bgDesc.depthAttachmentPixelFormat      = .depth32Float
            do {
                background = try device.makeRenderPipelineState(descriptor: bgDesc)
                print("[DEBUG] ScenePipeline: background pipeline created")
            } catch {
                print("[DEBUG] ScenePipeline: background pipeline failed — " + error.localizedDescription)
            }
            let bgDepthDesc = MTLDepthStencilDescriptor()
            bgDepthDesc.depthCompareFunction = .always
            bgDepthDesc.isDepthWriteEnabled  = false
            backgroundDepth = device.makeDepthStencilState(descriptor: bgDepthDesc)
        } else {
            print("[DEBUG] ScenePipeline: background shaders not found")
        }

        // ── Environment skybox pipeline ───────────────────────────────────────
        if let skyVertFn = library.makeFunction(name: "skybox_vertex"),
           let skyFragFn = library.makeFunction(name: "skybox_fragment") {
            let skyDesc = MTLRenderPipelineDescriptor()
            skyDesc.vertexFunction   = skyVertFn
            skyDesc.fragmentFunction = skyFragFn
            skyDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
            skyDesc.depthAttachmentPixelFormat      = .depth32Float
            do {
                skybox = try device.makeRenderPipelineState(descriptor: skyDesc)
                print("[DEBUG] ScenePipeline: skybox pipeline created")
            } catch {
                print("[DEBUG] ScenePipeline: skybox pipeline failed — " + error.localizedDescription)
            }
        } else {
            print("[DEBUG] ScenePipeline: skybox shaders not found")
        }

        // ── Laser beam billboard pipeline ─────────────────────────────────────
        if let laserVertFn = library.makeFunction(name: "laser_beam_vertex"),
           let laserFragFn = library.makeFunction(name: "laser_beam_fragment") {
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
                laserBeam = try device.makeRenderPipelineState(descriptor: laserDesc)
                print("[DEBUG] ScenePipeline: laser beam pipeline created")
            } catch {
                print("[DEBUG] ScenePipeline: laser beam pipeline failed — " + error.localizedDescription)
            }
            let laserDepthDesc = MTLDepthStencilDescriptor()
            laserDepthDesc.depthCompareFunction = .lessEqual
            laserDepthDesc.isDepthWriteEnabled  = false   // read-only depth test
            laserBeamDepth = device.makeDepthStencilState(descriptor: laserDepthDesc)
        } else {
            print("[DEBUG] ScenePipeline: laser beam shaders not found")
        }

        // ── Laser hit effect pipeline ─────────────────────────────────────────
        if let hitVertFn = library.makeFunction(name: "laser_hit_vertex"),
           let hitFragFn = library.makeFunction(name: "laser_hit_fragment") {
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
                laserHit = try device.makeRenderPipelineState(descriptor: hitDesc)
                print("[DEBUG] ScenePipeline: laser hit pipeline created")
            } catch {
                print("[DEBUG] ScenePipeline: laser hit pipeline failed — " + error.localizedDescription)
            }
        } else {
            print("[DEBUG] ScenePipeline: laser hit shaders not found")
        }

        // ── Spark particle pipeline ───────────────────────────────────────────
        if let sparkVertFn = library.makeFunction(name: "spark_vertex"),
           let sparkFragFn = library.makeFunction(name: "spark_fragment") {
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
                spark = try device.makeRenderPipelineState(descriptor: sparkDesc)
                print("[DEBUG] ScenePipeline: spark pipeline created")
            } catch {
                print("[DEBUG] ScenePipeline: spark pipeline failed — " + error.localizedDescription)
            }
        } else {
            print("[DEBUG] ScenePipeline: spark shaders not found")
        }

        // ── Weather particle pipeline (instanced billboards, alpha blend) ──────
        if let pVert = library.makeFunction(name: "particlefx_vertex"),
           let pFrag = library.makeFunction(name: "particlefx_fragment") {
            let pDesc = MTLRenderPipelineDescriptor()
            pDesc.label                           = "ParticleFX"
            pDesc.vertexFunction                  = pVert
            pDesc.fragmentFunction                = pFrag
            pDesc.depthAttachmentPixelFormat      = .depth32Float
            let ca = pDesc.colorAttachments[0]!
            ca.pixelFormat                 = .bgra8Unorm
            ca.isBlendingEnabled           = true
            ca.sourceRGBBlendFactor        = .sourceAlpha
            ca.destinationRGBBlendFactor   = .oneMinusSourceAlpha
            ca.rgbBlendOperation           = .add
            ca.sourceAlphaBlendFactor      = .sourceAlpha
            ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            ca.alphaBlendOperation         = .add
            do {
                particleFX = try device.makeRenderPipelineState(descriptor: pDesc)
                print("[DEBUG] ScenePipeline: particle pipeline created")
            } catch {
                print("[DEBUG] ScenePipeline: particle pipeline failed — " + error.localizedDescription)
            }
        } else {
            print("[DEBUG] ScenePipeline: particlefx shaders not found")
        }

        // ── Fog volume pipeline (fullscreen raymarch, source-over blend) ───────
        if let fVert = library.makeFunction(name: "fogvolume_vertex"),
           let fFrag = library.makeFunction(name: "fogvolume_fragment") {
            let fDesc = MTLRenderPipelineDescriptor()
            fDesc.label             = "FogVolume"
            fDesc.vertexFunction    = fVert
            fDesc.fragmentFunction  = fFrag
            let ca = fDesc.colorAttachments[0]!
            ca.pixelFormat                 = .bgra8Unorm
            ca.isBlendingEnabled           = true
            ca.sourceRGBBlendFactor        = .sourceAlpha
            ca.destinationRGBBlendFactor   = .oneMinusSourceAlpha
            ca.rgbBlendOperation           = .add
            ca.sourceAlphaBlendFactor      = .one
            ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            ca.alphaBlendOperation         = .add
            do {
                fogVolume = try device.makeRenderPipelineState(descriptor: fDesc)
                print("[DEBUG] ScenePipeline: fog volume pipeline created")
            } catch {
                print("[DEBUG] ScenePipeline: fog volume pipeline failed — " + error.localizedDescription)
            }
        } else {
            print("[DEBUG] ScenePipeline: fogvolume shaders not found")
        }

        // ── Color grade pipeline (fullscreen pass, no depth) ──────────────────
        if let gradeVertFn = library.makeFunction(name: "color_grade_vertex"),
           let gradeFragFn = library.makeFunction(name: "color_grade_fragment") {
            let gradeDesc = MTLRenderPipelineDescriptor()
            gradeDesc.label                             = "ColorGrade"
            gradeDesc.vertexFunction                    = gradeVertFn
            gradeDesc.fragmentFunction                  = gradeFragFn
            gradeDesc.colorAttachments[0].pixelFormat   = .bgra8Unorm
            // No depth attachment, no blending — every pixel is overwritten
            do {
                colorGrade = try device.makeRenderPipelineState(descriptor: gradeDesc)
                print("[DEBUG] ScenePipeline: color grade pipeline created")
            } catch {
                print("[DEBUG] ScenePipeline: color grade pipeline failed — " + error.localizedDescription)
            }
        } else {
            print("[DEBUG] ScenePipeline: color_grade shaders not found")
        }

        self.backgroundPipelineState = background
        self.backgroundDepthState    = backgroundDepth
        self.skyboxPipelineState     = skybox
        self.laserBeamPipelineState  = laserBeam
        self.laserBeamDepthState     = laserBeamDepth
        self.laserHitPipelineState   = laserHit
        self.sparkPipelineState      = spark
        self.particleFXPipelineState = particleFX
        self.fogVolumePipelineState  = fogVolume
        self.colorGradePipelineState = colorGrade
    }

    // MARK: - Pass encoders

    /// Background gradient OR environment skybox, drawn into the caller's open
    /// scene encoder before geometry.  The ONLY copy of this draw — both the live
    /// viewport and the exporter route through here so they can't drift.
    func encodeBackground(into encoder: MTLRenderCommandEncoder, _ ctx: SceneRenderContext) {
        if ctx.background.mode == .gradient,
           let bgPipe  = backgroundPipelineState,
           let bgDepth = backgroundDepthState {
            encoder.setRenderPipelineState(bgPipe)
            encoder.setDepthStencilState(bgDepth)
            encoder.setCullMode(.none)
            var bgUniforms = ctx.background.backgroundUniforms
            encoder.setFragmentBytes(&bgUniforms,
                                     length: MemoryLayout<BackgroundUniforms>.stride,
                                     index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        else if ctx.background.mode == .environment,
                let skyPipe = skyboxPipelineState,
                let bgDepth = backgroundDepthState,
                let ibl     = ctx.ibl,
                let cube    = ibl.envCubemap {
            encoder.setRenderPipelineState(skyPipe)
            encoder.setDepthStencilState(bgDepth)
            encoder.setCullMode(.none)
            let bgEquirect = ctx.backgroundEquirect ?? ibl.envEquirect   // dedicated bg, else lighting env
            var sky = SkyboxUniforms(
                inverseViewProjection: simd_inverse(ctx.viewProjection),
                cameraPos:             SIMD4<Float>(ctx.eyePosition, 1),
                intensity:             ctx.background.environmentIntensity,
                horizon:               ctx.background.environmentHorizon,
                useEquirect:           bgEquirect != nil ? 1 : 0,
                colorMode:             UInt32(ctx.colorMode.rawValue))
            encoder.setFragmentBytes(&sky,
                                     length: MemoryLayout<SkyboxUniforms>.stride,
                                     index: 0)
            encoder.setFragmentTexture(cube, index: 0)
            encoder.setFragmentTexture(bgEquirect ?? ctx.dummyEquirect, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }

    /// Raymarched fog volume composited over `dest` (which already holds the
    /// scene), reading `depthTex` for occlusion.  Its own render pass (source-over
    /// blend, no destination read) so it works over the drawable or the exporter's
    /// colour texture.  The caller gates this on feedback being off (the feedback
    /// depth isn't sampleable); a disabled/nil fog also no-ops here.
    func encodeFogVolume(commandBuffer: MTLCommandBuffer,
                         dest:          MTLTexture,
                         depthTex:      MTLTexture,
                         _ ctx:         SceneRenderContext) {
        guard let fog = ctx.fog, fog.isEnabled,
              let pipe = fogVolumePipelineState else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture     = dest
        pass.colorAttachments[0].loadAction  = .load
        pass.colorAttachments[0].storeAction = .store
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var u = makeFogVolumeUniforms(fog,
            at:             ctx.time,
            playing:        ctx.playing,
            viewProjection: ctx.viewProjection,
            cameraPos:      ctx.eyePosition,
            colorMode:      ctx.colorMode.rawValue)
        enc.setRenderPipelineState(pipe)
        enc.setFragmentBytes(&u, length: MemoryLayout<FogVolumeUniforms>.stride, index: 0)
        enc.setFragmentTexture(depthTex, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }
}
