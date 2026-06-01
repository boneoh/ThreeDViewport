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
    // Holdout pipeline — identical to the scene pipeline but with color writes
    // masked off, so holdout objects write depth (occluding others) without
    // drawing themselves.  Uses the same depthStencilState.
    var holdoutPipelineState: MTLRenderPipelineState?
    // Transparent pipeline — same shaders as the scene pipeline but with alpha
    // blending on (src=sourceAlpha, dst=oneMinusSourceAlpha) and depth writes
    // disabled.  Used for parts whose material.opacity < 1; drawn after opaque
    // geometry, sorted back-to-front.  Alpha channel preserves dest.a so the
    // feedback compositor still distinguishes geometry from background.
    var transparentPipelineState: MTLRenderPipelineState?
    var transparentDepthState:    MTLDepthStencilState?

    // Background gradient pipeline
    var backgroundPipelineState: MTLRenderPipelineState?
    var backgroundDepthState: MTLDepthStencilState?
    // Environment skybox pipeline — samples the IBL env by camera-ray direction.
    var skyboxPipelineState: MTLRenderPipelineState?
    private var dummyEquirect: MTLTexture?   // 1×1 placeholder for the equirect slot
    /// Optional dedicated background HDR equirect.  When set, the skybox samples
    /// this instead of the lighting (IBL) equirect, so backdrop and lighting can
    /// use different HDRs.  Nil = mirror the lighting environment.
    var backgroundEquirect: MTLTexture?

    // Fallback buffers — bound when an object has no UVs or tangents so
    // buffer(4)/buffer(5) are always valid Metal bindings.
    private var dummyUVBuffer:      MTLBuffer?   // single float2
    private var dummyTangentBuffer: MTLBuffer?   // single float4

    // MARK: - Scene references

    let sceneManager:     SceneManager
    let camera:           CameraController
    /// Director's-POV camera used for rendering when `sceneModeActive` is true.
    /// Separate from `camera` so the scene camera (the one being recorded /
    /// animated) is untouched while the user looks at the scene from above.
    let director:         CameraController
    /// When true, the renderer draws from the director's POV instead of the
    /// scene camera.  Scene-camera animation / follow logic continues to run
    /// (so the scene camera moves on its track), but the *view* is the director's.
    var sceneModeActive:  Bool = false

    /// Scene-mode "solo" view aids (mirrored from ViewportView, keys 7 / 8).
    /// When `sceneSoloHideOthers` is set, only the selected object's group is drawn;
    /// when `sceneSoloOccludeOthers` is also set, the hidden others still occlude
    /// (depth-only).  Non-destructive — object isVisible is never changed.
    var sceneSoloHideOthers:    Bool = false
    var sceneSoloOccludeOthers: Bool = false

    /// Which selected entity's keyframe motion path the 'V' overlay traces.
    enum MotionVectorTarget { case none, camera, light, object }
    /// Toggled by the 'V' key (set from ViewportView).  When != .none, the live
    /// viewport draws a red dot at each keyframe of the selected entity joined by
    /// a light-grey path.  Editor-only — never exported.
    var motionVectorTarget: MotionVectorTarget = .none

    /// The camera whose `viewMatrix` / `viewProjectionMatrix` / `eyePosition`
    /// the renderer should sample this frame.  Centralises the "scene mode swap"
    /// so individual draw paths don't have to branch.
    private var viewCamera: CameraController {
        return sceneModeActive ? director : camera
    }
    let lightManager:     LightManager
    let backgroundConfig: BackgroundConfig
    let timeline:         Timeline

    // MARK: - Render mode

    var isWireframe:   Bool = false
    var colorMode:     RenderColorMode = .color   // greyscale / color / black + white
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

    // Scene-mode widget pipeline (solid colour lines, depth-tested no write).
    // Lazy: built by `buildPipeline()`; used only while `sceneModeActive`.
    private var widgetPipelineState:    MTLRenderPipelineState?

    // MARK: - Feedback (optional — set by ViewportView after init)

    var feedbackProcessor: FeedbackProcessor?
    var feedbackSettings:  FeedbackSettings?

    // MARK: - Color grade (optional — set by ViewportView after init)

    var colorGradeSettings:    ColorGradeSettings?
    private var colorGradePipeline: MTLRenderPipelineState?

    // MARK: - Fog volume (optional — set by ViewportView after init)
    var fogSettings: FogSettings?
    private var fogVolumePipelineState: MTLRenderPipelineState?
    // Sampleable scene depth, allocated lazily only when the fog volume is on and
    // feedback is off.  The scene renders straight to the drawable with this as its
    // depth attachment; the fog pass then samples it to clamp rays to scene depth.
    private var fogSceneDepth: MTLTexture?

    // MARK: - Weather particles (optional — set by ViewportView after init)
    var particleManager: ParticleManager?
    private var particleFXPipelineState: MTLRenderPipelineState?
    private var particleSeedBuffer:      MTLBuffer?
    private var gradeTexture:  MTLTexture?   // intermediate; rebuilt on size change

    // MARK: - Laser hit effect

    private var laserHitSystem:   LaserHitSystem   = LaserHitSystem()
    private var hitEffectTime:    Float             = 0
    private var lastDrawWallTime: CFAbsoluteTime    = 0

    // Non-published render copy of the lights.  During PLAYBACK, applyAnimation
    // writes animated light values here (not to the @Published lightManager.lights)
    // so the Lights inspector doesn't re-render every frame.  While paused, it
    // mirrors lightManager.lights so inspector edits show immediately.  All of the
    // renderer's GPU/laser/widget light reads use this.
    private var animatedLights:   [LightConfig]     = []

    // MARK: - Performance instrumentation
    // Flip to `true` to log a rolling 1-second average of per-frame CPU encode
    // time (top of draw → commit), GPU frame time (gpuEndTime − gpuStartTime),
    // and achieved FPS to the console.  Leave `false` for normal use.
    static let perfLoggingEnabled = false
    private let perfLock        = NSLock()
    private var perfWindowStart: CFAbsoluteTime = 0
    private var perfFrameCount  = 0
    private var perfCPUAccum:    Double = 0   // ms
    private var perfGPUAccum:    Double = 0   // ms

    private var lastAnimatedTime: Double = -1.0
    /// Last playhead time the atmosphere panels were synced to while paused, so
    /// scrubbing makes the Fog/Weather panel + paused render follow the playhead
    /// without re-syncing every frame (which would clobber live slider edits).
    private var lastAtmoSyncTime: Double = -1.0
    /// currentTime at end of previous frame — detects manual scrub while paused.
    private var lastRenderedTime: Double = -1.0
    /// isPlaying state at end of previous frame — lets us distinguish "just stopped"
    /// (natural end of playback) from "scrubbed while paused".
    private var lastWasPlaying:   Bool   = false

    // Editor-only bake probe (drawn as an axis gizmo in the live view; never exported).
    var probeConfig: ProbeConfig?

    // Phase C: image-based lighting resources (BRDF LUT, env cubemaps).
    // nil until precompute finishes; the scene shader gates IBL sampling on
    // texture presence so a nil here just disables the IBL contribution.
    var ibl: IBL?

    // MARK: - Init

    init?(device: MTLDevice,
          sceneManager: SceneManager,
          camera: CameraController,
          director: CameraController,
          lightManager: LightManager,
          backgroundConfig: BackgroundConfig,
          timeline: Timeline) {

        self.device           = device
        self.sceneManager     = sceneManager
        self.camera           = camera
        self.director         = director
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
        buildIBL()
    }

    private func buildIBL() {
        guard let library = try? device.makeDefaultLibrary(bundle: Bundle.module) else {
            print("[DEBUG] Renderer: buildIBL — makeDefaultLibrary failed")
            return
        }
        ibl = IBL(device: device, library: library, commandQueue: commandQueue)
        if ibl == nil { print("[DEBUG] Renderer: IBL precompute failed") }
    }

    /// Hot-swaps the Lighting HDR (rebuilds the IBL environment).  `url == nil`
    /// reverts to the bundled HDR.  Returns false if no environment could build.
    @discardableResult
    func reloadLightingHDR(_ url: URL?) -> Bool {
        return ibl?.reloadEnvironment(hdrURL: url) ?? false
    }

    /// Sets (or clears) the dedicated Background HDR backdrop.  `url == nil` clears
    /// it so the skybox mirrors the lighting environment.  Returns false if a URL
    /// was given but couldn't be loaded.
    @discardableResult
    func setBackgroundHDR(_ url: URL?) -> Bool {
        guard let url else { backgroundEquirect = nil; return true }
        if let tex = IBL.loadEquirectTexture(url: url, device: device) {
            backgroundEquirect = tex
            return true
        }
        return false
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

        // Holdout variant: same vertex transform, but a dedicated fragment that
        // writes a transparent matte (RGB 0, alpha 0) with full colour writes and
        // blending off — so the holdout silhouette overwrites the background
        // skybox with a clean hole while still writing depth to occlude geometry
        // behind it.
        let holdoutFragmentFn = library.makeFunction(name: "holdout_fragment")
        pipelineDesc.fragmentFunction = holdoutFragmentFn
        do {
            holdoutPipelineState = try device.makeRenderPipelineState(descriptor: pipelineDesc)
            print("[DEBUG] Renderer: holdout pipeline created")
        } catch {
            print("[DEBUG] Renderer: holdout pipeline failed — " + error.localizedDescription)
        }
        pipelineDesc.fragmentFunction = fragmentFn   // restore for any later reuse

        // Transparent variant: same shaders, alpha blending on for the color
        // channels (over-compositing), but alpha-channel write is configured
        // to preserve the destination's existing alpha — so the feedback
        // compositor still sees geometry pixels as a=1.
        let tCA = pipelineDesc.colorAttachments[0]!
        tCA.isBlendingEnabled                 = true
        tCA.rgbBlendOperation                 = .add
        tCA.sourceRGBBlendFactor              = .sourceAlpha
        tCA.destinationRGBBlendFactor         = .oneMinusSourceAlpha
        tCA.alphaBlendOperation               = .add
        tCA.sourceAlphaBlendFactor            = .zero
        tCA.destinationAlphaBlendFactor       = .one
        do {
            transparentPipelineState = try device.makeRenderPipelineState(descriptor: pipelineDesc)
            print("[DEBUG] Renderer: transparent pipeline created")
        } catch {
            print("[DEBUG] Renderer: transparent pipeline failed — " + error.localizedDescription)
        }
        // Restore opaque blend state on the descriptor for any later reuse.
        tCA.isBlendingEnabled = false

        let depthDesc = MTLDepthStencilDescriptor()
        depthDesc.depthCompareFunction = .less
        depthDesc.isDepthWriteEnabled  = true
        depthStencilState = device.makeDepthStencilState(descriptor: depthDesc)

        // Transparent depth state — test AND write.  For a single closed mesh
        // we need depth writes so the front-facing triangles occlude the
        // back-facing ones; with depth-write off, back faces drawn later in
        // the index buffer composite over the front faces and the surface
        // breaks into diagonal seams.  The cost is that two transparent
        // objects which *intersect* will clip at the crossing — but our
        // back-to-front sort already handles non-intersecting overlap
        // correctly, and intersecting transparent objects need OIT to look
        // right regardless of how depth is configured.
        let tDepthDesc = MTLDepthStencilDescriptor()
        tDepthDesc.depthCompareFunction = .less
        tDepthDesc.isDepthWriteEnabled  = true
        transparentDepthState = device.makeDepthStencilState(descriptor: tDepthDesc)

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

        // ── Environment skybox pipeline ───────────────────────────────────────
        if let skyVertFn = library.makeFunction(name: "skybox_vertex"),
           let skyFragFn = library.makeFunction(name: "skybox_fragment") {
            let skyDesc = MTLRenderPipelineDescriptor()
            skyDesc.vertexFunction   = skyVertFn
            skyDesc.fragmentFunction = skyFragFn
            skyDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
            skyDesc.depthAttachmentPixelFormat      = .depth32Float
            do {
                skyboxPipelineState = try device.makeRenderPipelineState(descriptor: skyDesc)
                print("[DEBUG] Renderer: skybox pipeline created")
            } catch {
                print("[DEBUG] Renderer: skybox pipeline failed — " + error.localizedDescription)
            }
        } else {
            print("[DEBUG] Renderer: skybox shaders not found")
        }

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

        // ── Scene-mode widget pipeline (lines, depth-tested no write, no blend) ─
        guard let widgetVertFn = library.makeFunction(name: "widget_vertex"),
              let widgetFragFn = library.makeFunction(name: "widget_fragment") else {
            print("[DEBUG] Renderer: widget shaders not found")
            return
        }
        let widgetDesc = MTLRenderPipelineDescriptor()
        widgetDesc.label                           = "SceneWidget"
        widgetDesc.vertexFunction                  = widgetVertFn
        widgetDesc.fragmentFunction                = widgetFragFn
        widgetDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        widgetDesc.depthAttachmentPixelFormat      = .depth32Float
        // Opaque widget colour, no blending — overwrite scene pixels where the
        // line passes the depth test.  (The line is one pixel wide and rasterised
        // along the primitive edges; tinting via blending isn't useful here.)
        do {
            widgetPipelineState = try device.makeRenderPipelineState(descriptor: widgetDesc)
            print("[DEBUG] Renderer: widget pipeline created")
        } catch {
            print("[DEBUG] Renderer: widget pipeline failed — " + error.localizedDescription)
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
                particleFXPipelineState = try device.makeRenderPipelineState(descriptor: pDesc)
                print("[DEBUG] Renderer: particle pipeline created")
            } catch {
                print("[DEBUG] Renderer: particle pipeline failed — " + error.localizedDescription)
            }
        } else {
            print("[DEBUG] Renderer: particlefx shaders not found")
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
                fogVolumePipelineState = try device.makeRenderPipelineState(descriptor: fDesc)
                print("[DEBUG] Renderer: fog volume pipeline created")
            } catch {
                print("[DEBUG] Renderer: fog volume pipeline failed — " + error.localizedDescription)
            }
        } else {
            print("[DEBUG] Renderer: fogvolume shaders not found")
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

        // 1×1 placeholder bound to the skybox's equirect slot when the IBL has no
        // equirect source (procedural sky), so texture(1) is always a valid binding.
        let dDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
        dDesc.usage = [.shaderRead]
        dummyEquirect = device.makeTexture(descriptor: dDesc)

        // Static, deterministic weather-particle seed pool (positions + phase).
        let seeds = ParticleEffect.makeSeeds()
        particleSeedBuffer = device.makeBuffer(bytes: seeds,
                                               length: seeds.count * MemoryLayout<SIMD4<Float>>.stride,
                                               options: .storageModeShared)
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        let aspect = Float(size.width / size.height)
        camera.aspectRatio   = aspect
        director.aspectRatio = aspect
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

    /// (Re)builds the sampleable scene depth texture the fog volume pass reads.
    private func rebuildFogSceneDepth(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        depthDesc.usage       = [.shaderRead, .renderTarget]
        depthDesc.storageMode = .private
        fogSceneDepth = device.makeTexture(descriptor: depthDesc)
        print("[DEBUG] Renderer: fog scene depth rebuilt \(width)×\(height)")
    }

    /// Composites the raymarched fog volume over `dest` (which already holds the
    /// scene), reading `depthTex` for occlusion.  Source-over blend; no read of the
    /// destination, so it works over the drawable and the exporter's colour texture.
    private func drawFogVolume(commandBuffer: MTLCommandBuffer,
                               dest:          MTLTexture,
                               depthTex:      MTLTexture) {
        guard let fog = fogSettings, fog.isEnabled,
              let pipe = fogVolumePipelineState else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture     = dest
        pass.colorAttachments[0].loadAction  = .load
        pass.colorAttachments[0].storeAction = .store
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var u = makeFogVolumeUniforms(fog,
            at:             timeline.renderTime,
            playing:        timeline.isPlaying,
            viewProjection: viewCamera.viewProjectionMatrix,
            cameraPos:      viewCamera.eyePosition,
            colorMode:      colorMode.rawValue)
        enc.setRenderPipelineState(pipe)
        enc.setFragmentBytes(&u, length: MemoryLayout<FogVolumeUniforms>.stride, index: 0)
        enc.setFragmentTexture(depthTex, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    /// While the timeline is paused, makes the Fog/Weather panel + paused render
    /// follow the playhead: on each scrub (time change) the static panel fields are
    /// set to the resolved keyframe value at the current frame.  Skipped while
    /// playing (the render reads the track directly) and when the time is unchanged
    /// (so live slider edits at a held frame aren't clobbered).
    private func syncAtmosphereToPlayhead() {
        guard !timeline.isPlaying else { return }
        let t = timeline.renderTime
        guard t != lastAtmoSyncTime else { return }
        lastAtmoSyncTime = t
        fogSettings?.syncToPlayhead(at: t)
        particleManager?.emitters.forEach { $0.syncToPlayhead(at: t) }
    }

    /// The "kept" object set for Scene-mode solo: the selected object's group
    /// (all members sharing its groupID), or just the selected object if it has no
    /// group.  Returns nil when there's no selection (so solo shows everything
    /// rather than blanking the view).
    private func soloKeptGroup() -> [SceneObject]? {
        guard let sel = sceneManager.selectedObject else { return nil }
        if let gid = sel.groupID {
            return sceneManager.objects(inGroup: gid)
        }
        return [sel]
    }

    /// Draws every enabled weather emitter into the open scene encoder, at the
    /// given timeline time (so live/scrub/export all agree).  Depth-tested against
    /// scene geometry, alpha-blended, no depth write.
    private func drawParticleEffects(encoder: MTLRenderCommandEncoder, time: Double) {
        guard let mgr   = particleManager,
              let pipe  = particleFXPipelineState,
              let seeds = particleSeedBuffer,
              let ds    = laserBeamDepthState else { return }
        let playing = timeline.isPlaying

        encoder.setRenderPipelineState(pipe)
        encoder.setDepthStencilState(ds)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(seeds, offset: 0, index: 0)

        for fx in mgr.emitters where fx.isEnabled {
            let density = fx.renderState(at: time, playing: playing).density
            let count = Int((max(0, min(1, density)) * Float(ParticleEffect.maxCount)).rounded())
            guard count > 0 else { continue }

            var u = makeParticleFXUniforms(fx,
                viewProjection: viewCamera.viewProjectionMatrix,
                cameraRight:    viewCamera.rightVector,
                cameraUp:       viewCamera.upVector,
                time:           Float(time),
                playing:        playing,
                colorMode:      colorMode.rawValue)

            encoder.setVertexBytes(&u, length: MemoryLayout<ParticleFXUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&u, length: MemoryLayout<ParticleFXUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                   instanceCount: count)
        }
    }

    func draw(in view: MTKView) {
        let perfDrawStart = Renderer.perfLoggingEnabled ? CFAbsoluteTimeGetCurrent() : 0

        // Wall-clock dt for hit effect animation (independent of timeline)
        let now = CFAbsoluteTimeGetCurrent()
        let dt  = lastDrawWallTime > 0 ? Float(now - lastDrawWallTime) : (1.0 / 60.0)
        lastDrawWallTime = now
        hitEffectTime += dt

        // Advance the playhead by real elapsed time (clamped so a hitch doesn't
        // jump the animation), decoupling playback speed from the draw rate.
        timeline.tick(dt: min(Double(dt), 1.0 / 15.0))

        // Reset feedback only when the user manually scrubs while already paused.
        // "Just stopped" (isPlaying flipped to false this frame) must NOT reset —
        // that would wipe the last feedback frame at the natural end of playback.
        let justStopped = lastWasPlaying && !timeline.isPlaying
        if !timeline.isPlaying && !justStopped && timeline.renderTime != lastRenderedTime {
            feedbackProcessor?.reset()
        }
        // On the play→pause/stop transition, publish the final animated light
        // values once so the (frozen-during-playback) inspector lands correctly.
        if justStopped, animatedLights.count == lightManager.lights.count {
            lightManager.lights = animatedLights
        }
        lastWasPlaying   = timeline.isPlaying
        lastRenderedTime = timeline.renderTime

        if timeline.renderTime != lastAnimatedTime {
            applyAnimation()
            lastAnimatedTime = timeline.renderTime
        }
        // While not playing, keep the render-facing light copy in sync with the
        // editor copy every frame so inspector edits show immediately.  (During
        // playback applyAnimation maintains animatedLights instead.)
        if !timeline.isPlaying { animatedLights = lightManager.lights }
        // FK hierarchy: recompute world transforms for all hierarchical parts
        // every frame, not just when time changes, so interactive manipulation
        // of a parent (e.g. rotating an upper arm) propagates to children
        // immediately regardless of whether animation is playing.
        applyHierarchy()
        // Camera follow is evaluated AFTER applyHierarchy so that sub-part world
        // transforms (e.g. a head bone) are fully up-to-date before worldOrbitAnchor
        // reads them.  Also runs every frame — not just when time changes — so the
        // camera stays locked to a moving target while playback is active.
        applyCameraFollow()

        // Make the Fog/Weather panel + paused render follow the playhead on scrub.
        syncAtmosphereToPlayhead()

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

        // Fog volume: when enabled and feedback is off, render the scene straight
        // to the drawable but with a sampleable depth texture as the depth target,
        // then composite the raymarched fog over the drawable reading that depth.
        // (Feedback + fog is skipped for now — the feedback depth isn't sampleable.)
        let fogActive       = (fogSettings?.isEnabled == true)
        let useFogOffscreen = fogActive && !feedbackActive
        if useFogOffscreen {
            let w = drawable.texture.width, h = drawable.texture.height
            if fogSceneDepth?.width != w || fogSceneDepth?.height != h {
                rebuildFogSceneDepth(width: w, height: h)
            }
        }

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
        } else if useFogOffscreen, let depthTex = fogSceneDepth {
            // Scene → drawable colour, but depth → our sampleable texture.
            let desc = MTLRenderPassDescriptor()
            desc.colorAttachments[0].texture     = drawable.texture
            desc.colorAttachments[0].loadAction  = .clear
            desc.colorAttachments[0].storeAction = .store
            desc.colorAttachments[0].clearColor  = backgroundConfig.clearColor
            desc.depthAttachment.texture         = depthTex
            desc.depthAttachment.loadAction      = .clear
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
        // ── Environment skybox ────────────────────────────────────────────────
        else if backgroundConfig.mode == .environment,
                let skyPipe = skyboxPipelineState,
                let bgDepth = backgroundDepthState,
                let ibl     = ibl,
                let cube    = ibl.envCubemap {
            encoder.setRenderPipelineState(skyPipe)
            encoder.setDepthStencilState(bgDepth)
            encoder.setCullMode(.none)
            let bgEquirect = backgroundEquirect ?? ibl.envEquirect   // dedicated bg, else lighting env
            var sky = SkyboxUniforms(
                inverseViewProjection: simd_inverse(viewCamera.viewProjectionMatrix),
                cameraPos:             SIMD4<Float>(viewCamera.eyePosition, 1),
                intensity:             backgroundConfig.environmentIntensity,
                horizon:               backgroundConfig.environmentHorizon,
                useEquirect:           bgEquirect != nil ? 1 : 0,
                colorMode:             UInt32(colorMode.rawValue))
            encoder.setFragmentBytes(&sky,
                                     length: MemoryLayout<SkyboxUniforms>.stride,
                                     index: 0)
            encoder.setFragmentTexture(cube, index: 0)
            encoder.setFragmentTexture(bgEquirect ?? dummyEquirect, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        // ── Scene geometry ────────────────────────────────────────────────────
        // Do NOT early-return here: even an empty scene must go through the
        // feedback path so fp.process ticks every frame and the drawable gets
        // content when feedback is rendering to sceneTexture.
        //
        // Scene-mode "solo": when active (and a selection exists), only the
        // selected object's group is drawn.  Non-kept objects are hidden, or — if
        // sceneSoloOccludeOthers — kept as depth-only holdouts.  This never mutates
        // object isVisible; it's purely a view override for the live preview.
        let visibleObjects: [SceneObject]
        let holdoutObjects: [SceneObject]
        // Transparent parts (e.g. glass windows) must NOT act as holdout occluders:
        // they don't block weather/fog when visible, so a depth-only holdout of the
        // glass would wrongly hide the FX behind it.  Only solid geometry holds out.
        func isTransparentMat(_ o: SceneObject) -> Bool {
            o.material.opacity < 1.0 || o.material.baseColorFactor.w < 1.0
        }
        let soloKept = (sceneModeActive && sceneSoloHideOthers)
            ? soloKeptGroup() : nil
        if let kept = soloKept {
            visibleObjects = kept.filter { $0.isVisible }
            holdoutObjects = sceneManager.objects.filter { obj in
                if isTransparentMat(obj) { return false }
                if kept.contains(where: { $0 === obj }) {
                    return !obj.isVisible && obj.occludeWhenHidden     // normal rule, kept group
                } else {
                    return sceneSoloOccludeOthers                       // others: occlude only with key 8
                }
            }
        } else {
            visibleObjects = sceneManager.objects.filter { $0.isVisible }
            // Holdout objects: hidden but flagged to occlude.  Drawn depth-only BEFORE
            // visible geometry so visible fragments behind them are cut to background.
            holdoutObjects = sceneManager.objects.filter {
                !$0.isVisible && $0.occludeWhenHidden && !isTransparentMat($0)
            }
        }

        if !holdoutObjects.isEmpty, let ds = depthStencilState, let holdout = holdoutPipelineState {
            SceneGeometryEncoder.encode(
                into:            encoder,
                objects:         holdoutObjects,
                groupTransforms: sceneManager.groupTransforms,
                lightUniforms:   lightManager.buildLightUniforms(from: animatedLights),
                context: SceneGeometryEncoder.Context(
                    viewProjection:    viewCamera.viewProjectionMatrix,
                    eyePosition:       viewCamera.eyePosition,
                    pipelineState:     holdout,
                    depthStencilState: ds,
                    colorMode:         colorMode,
                    isWireframe:       false,   // holdout is depth-only; never wireframe
                    exposure:          colorGradeSettings?.exposure ?? 1.0,
                    ibl:               ibl,
                    dummyUV:           dummyUVBuffer,
                    dummyTangent:      dummyTangentBuffer,
                    dummy2D:           dummyEquirect))
        }

        // Split into opaque (opacity == 1) and transparent (< 1) draw lists.
        // Transparent parts are sorted back-to-front from the view camera so
        // the over-compositing blend produces a correct result; without the
        // sort, a near transparent surface drawn before a far one would
        // composite the far one against background instead of the near one.
        let opaqueObjects:      [SceneObject]
        let transparentObjects: [SceneObject]
        // A material renders transparent if either knob is < 1: the runtime
        // opacity slider, OR baseColorFactor.w baked into the GLB (the latter
        // is how Models/station/*.glb ships translucent window submeshes).
        // The shader multiplies the two, so we test both here for routing.
        func isTransparent(_ o: SceneObject) -> Bool {
            o.material.opacity < 1.0 || o.material.baseColorFactor.w < 1.0
        }
        if visibleObjects.contains(where: isTransparent) {
            opaqueObjects = visibleObjects.filter { !isTransparent($0) }
            let eye = viewCamera.eyePosition
            transparentObjects = visibleObjects
                .filter(isTransparent)
                .map { obj -> (SceneObject, Float) in
                    let m: matrix_float4x4
                    if let gid = obj.groupID, let gt = sceneManager.groupTransforms[gid] {
                        m = gt * obj.transform
                    } else {
                        m = obj.transform
                    }
                    let p = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
                    let d = p - eye
                    return (obj, dot(d, d))
                }
                .sorted { $0.1 > $1.1 }     // farthest first
                .map { $0.0 }
        } else {
            opaqueObjects      = visibleObjects
            transparentObjects = []
        }

        if !opaqueObjects.isEmpty, let ds = depthStencilState {
            SceneGeometryEncoder.encode(
                into:            encoder,
                objects:         opaqueObjects,
                groupTransforms: sceneManager.groupTransforms,
                lightUniforms:   lightManager.buildLightUniforms(from: animatedLights),
                context: SceneGeometryEncoder.Context(
                    viewProjection:    viewCamera.viewProjectionMatrix,
                    eyePosition:       viewCamera.eyePosition,
                    pipelineState:     pipeline,
                    depthStencilState: ds,
                    colorMode:         colorMode,
                    isWireframe:       isWireframe,
                    exposure:          colorGradeSettings?.exposure ?? 1.0,
                    ibl:               ibl,
                    dummyUV:           dummyUVBuffer,
                    dummyTangent:      dummyTangentBuffer,
                    dummy2D:           dummyEquirect))
        }

        // ── Weather particles (depth-tested against geometry, alpha-blended) ───
        // Drawn AFTER opaque but BEFORE transparent geometry: opaque surfaces
        // (e.g. the station hull) correctly occlude the smoke, while translucent
        // surfaces (glass windows) draw over it and composite — so the smoke
        // stays visible through the windows instead of being depth-rejected by
        // the glass, which writes depth.
        drawParticleEffects(encoder: encoder, time: timeline.renderTime)

        // ── Laser hit detection + particle update ─────────────────────────────
        // Beams/hits/sparks are drawn BEFORE transparent geometry (same reason as
        // the weather particles above): the glass windows write depth, so a
        // read-only beam fragment behind the glass would otherwise be
        // depth-rejected and vanish.  Drawn here, opaque surfaces still occlude
        // the beam and the translucent glass composites over it.
        let screenSize = SIMD2<Float>(Float(view.drawableSize.width),
                                      Float(view.drawableSize.height))
        let visibleForHits = sceneManager.objects.filter { $0.isVisible }
        laserHitSystem.updateHits(lights: animatedLights, objects: visibleForHits)
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

        if !transparentObjects.isEmpty,
           let tDS = transparentDepthState,
           let tP  = transparentPipelineState {
            SceneGeometryEncoder.encode(
                into:            encoder,
                objects:         transparentObjects,
                groupTransforms: sceneManager.groupTransforms,
                lightUniforms:   lightManager.buildLightUniforms(from: animatedLights),
                context: SceneGeometryEncoder.Context(
                    viewProjection:    viewCamera.viewProjectionMatrix,
                    eyePosition:       viewCamera.eyePosition,
                    pipelineState:     tP,
                    depthStencilState: tDS,
                    colorMode:         colorMode,
                    isWireframe:       isWireframe,
                    exposure:          colorGradeSettings?.exposure ?? 1.0,
                    ibl:               ibl,
                    dummyUV:           dummyUVBuffer,
                    dummyTangent:      dummyTangentBuffer,
                    dummy2D:           dummyEquirect))
        }

        // ── Scene-mode widgets (camera frustum + light gizmos) ────────────────
        // Drawn last in the main pass so they layer above geometry where depth
        // permits.  When feedback is active the trail will capture widgets too —
        // acceptable for an editing-only view.
        if sceneModeActive {
            drawSceneWidgets(encoder: encoder)
        }
        drawProbeGizmo(encoder: encoder)   // editor-only; not gated by scene mode, never exported
        drawMotionVectors(encoder: encoder) // editor-only 'V' overlay; never exported

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

        // ── Fog volume composite ──────────────────────────────────────────────
        // Raymarch the fog over the drawable (which now holds the scene), reading
        // the sampleable depth texture for occlusion.
        if useFogOffscreen, let depthTex = fogSceneDepth {
            drawFogVolume(commandBuffer: commandBuffer, dest: drawable.texture, depthTex: depthTex)
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

        // ── Color grade (brightness / contrast / gamma) — very last pass ─────
        if let settings = colorGradeSettings, !settings.isIdentity {
            // Build the intermediate lazily: drawableSizeWillChange can fire
            // before this renderer is assigned as the view's delegate, so
            // gradeTexture may still be nil on the first frames (it only got
            // built after a manual window resize).  Rebuild on size mismatch too.
            let w = drawable.texture.width
            let h = drawable.texture.height
            if gradeTexture == nil || gradeTexture?.width != w || gradeTexture?.height != h {
                rebuildGradeTexture(width: w, height: h)
            }
            if let gradeTex = gradeTexture {
                if let blit = commandBuffer.makeBlitCommandEncoder() {
                    blit.copy(from: drawable.texture, to: gradeTex)
                    blit.endEncoding()
                }
                applyColorGrade(commandBuffer: commandBuffer,
                                source: gradeTex,
                                dest:   drawable.texture,
                                settings: settings)
            }
        }

        if Renderer.perfLoggingEnabled {
            // CPU = main-thread frame build (animation + encode) up to commit.
            let cpuMs = (CFAbsoluteTimeGetCurrent() - perfDrawStart) * 1000.0
            commandBuffer.addCompletedHandler { [weak self] cb in
                let gpuMs = (cb.gpuEndTime - cb.gpuStartTime) * 1000.0
                self?.recordPerf(cpuMs: cpuMs, gpuMs: gpuMs)
            }
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Accumulates per-frame CPU/GPU timings and prints a rolling 1-second average.
    /// Called from the command buffer's completion handler (a Metal thread), so a
    /// lock guards the accumulators.
    private func recordPerf(cpuMs: Double, gpuMs: Double) {
        perfLock.lock()
        defer { perfLock.unlock() }
        let now = CFAbsoluteTimeGetCurrent()
        if perfWindowStart == 0 { perfWindowStart = now }
        perfCPUAccum   += cpuMs
        perfGPUAccum   += gpuMs
        perfFrameCount += 1
        let elapsed = now - perfWindowStart
        if elapsed >= 1.0, perfFrameCount > 0 {
            let n = Double(perfFrameCount)
            print(String(format: "[PERF] CPU %.1fms | GPU %.1fms | %.0f fps (%d frames)",
                         perfCPUAccum / n, perfGPUAccum / n, n / elapsed, perfFrameCount))
            perfCPUAccum = 0; perfGPUAccum = 0; perfFrameCount = 0; perfWindowStart = now
        }
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
        // Uses the active rendering camera so the gizmo orientation matches what's drawn.
        let vm = viewCamera.viewMatrix
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
        let indexedBeams = animatedLights.enumerated().filter {
            $0.element.type == .laser && $0.element.isEnabled &&
            $0.element.excludeBeamFromFeedback == excludedOnly
        }
        guard !indexedBeams.isEmpty else { return }

        encoder.setRenderPipelineState(pipeline)
        if let ds = laserBeamDepthState { encoder.setDepthStencilState(ds) }
        encoder.setCullMode(.none)

        let vp = viewCamera.viewProjectionMatrix
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
                color:      SIMD4<Float>(colorMode == .blackWhite ? SIMD3<Float>(repeating: 1) : laser.color, 1),
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
        let excludedBeams = animatedLights.enumerated().filter {
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
            let vp = viewCamera.viewProjectionMatrix
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
                    color:      SIMD4<Float>(colorMode == .blackWhite ? SIMD3<Float>(repeating: 1) : laser.color, 1),
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
        let vp = viewCamera.viewProjectionMatrix
        var pipelineSet = false

        for (i, laser) in animatedLights.enumerated() {
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
                color:      SIMD4<Float>(colorMode == .blackWhite ? SIMD3<Float>(repeating: 1) : hit.color,  1),
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
            viewProjectionMatrix: viewCamera.viewProjectionMatrix,
            cameraRight: SIMD4<Float>(viewCamera.rightVector, 0),
            cameraUp:    SIMD4<Float>(viewCamera.upVector,    0),
            colorMode:   UInt32(colorMode.rawValue)
        )
        encoder.setVertexBuffer(sparkBuf, offset: 0, index: 0)
        encoder.setVertexBytes(&su, length: MemoryLayout<SparkUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0,
                               vertexCount: 4, instanceCount: sparkGPUData.count)
    }

    // MARK: - Scene-mode widgets

    /// Draws Phase-2 / Phase-3 widgets (camera frustum, light gizmos) onto the
    /// main pass.  Only called when `sceneModeActive` is true.  Uses the laser
    /// beam depth state (depth-test on, depth-write off) so widgets occlude
    /// behind scene geometry but don't write to depth themselves.
    private func drawSceneWidgets(encoder: MTLRenderCommandEncoder) {
        guard let pipeline = widgetPipelineState else { return }

        encoder.setRenderPipelineState(pipeline)
        if let ds = laserBeamDepthState { encoder.setDepthStencilState(ds) }
        encoder.setCullMode(.none)

        let vp = viewCamera.viewProjectionMatrix

        // Shared widget scale — small enough to read at close-in framings,
        // large enough to remain visible when the Director zooms out.  Tied
        // to the scene camera's distance so all widgets scale together.
        let scale = max(0.25, min(camera.distance * 0.25, 1.0))

        // ── Scene-camera frustum (white) ──────────────────────────────────────
        var camVerts = SceneWidgets.cameraFrustum(eye:     camera.eyePosition,
                                                  forward: camera.forwardVector,
                                                  right:   camera.rightVector,
                                                  up:      camera.upVector,
                                                  fovY:    camera.fovYRadians,
                                                  aspect:  camera.aspectRatio,
                                                  depth:   scale)
        drawWidgetLines(encoder: encoder,
                        vertices: &camVerts,
                        viewProjection: vp,
                        color: SIMD4<Float>(1.0, 1.0, 1.0, 1.0))

        // ── Light gizmos ──────────────────────────────────────────────────────
        // Each light renders in its own configured colour so the user can map
        // the widget back to a light in the inspector.  Per-type shape so even
        // colour-blind users can distinguish types at a glance.
        for light in animatedLights where light.isEnabled {
            let color = SIMD4<Float>(light.color, 1.0)

            switch light.type {
            case .ambient:
                // No geometry — ambient has no position or direction.
                break

            case .directional:
                // Arrow at the scene-camera target showing which way the light
                // shines.  Length tracks the shared widget scale.
                var verts = SceneWidgets.directionalArrow(
                    anchor:    camera.target,
                    direction: light.direction,
                    length:    scale * 1.5)
                drawWidgetLines(encoder: encoder,
                                vertices: &verts,
                                viewProjection: vp,
                                color: color)

            case .point:
                // Small wireframe sphere at the light's position.
                var verts = SceneWidgets.sphereWireframe(
                    center:   light.position,
                    radius:   scale * 0.25)
                drawWidgetLines(encoder: encoder,
                                vertices: &verts,
                                viewProjection: vp,
                                color: color)

            case .spot, .laser:
                // Apex sphere + cone showing position, direction, and outer
                // cone angle (i.e. the beam's actual spread).  Cone length
                // capped so a long-range laser doesn't shoot off-screen.
                var apexSphere = SceneWidgets.sphereWireframe(
                    center:   light.position,
                    radius:   scale * 0.15)
                drawWidgetLines(encoder: encoder,
                                vertices: &apexSphere,
                                viewProjection: vp,
                                color: color)

                let coneLength = min(light.range * 0.5, scale * 3.0)
                var coneVerts = SceneWidgets.cone(
                    apex:      light.position,
                    direction: light.direction,
                    length:    coneLength,
                    halfAngle: light.outerConeAngle)
                drawWidgetLines(encoder: encoder,
                                vertices: &coneVerts,
                                viewProjection: vp,
                                color: color)
            }
        }

        // ── Ground scale ruler (world X through the origin) ───────────────────
        // Fixed 1-unit ticks, taller every 10, like a map scale bar.  Span is
        // capped so the vertex list stays within setVertexBytes' ~4 KB limit.
        let rulerHalf = min(max(camera.distance * 1.2, 5.0), 50.0)
        var ruler = SceneWidgets.scaleRuler(center: SIMD3<Float>(0, 0, 0),
                                            halfLength:  rulerHalf,
                                            unit:        1.0,
                                            minorHeight: scale * 0.15,
                                            majorHeight: scale * 0.5,
                                            majorEvery:  10)
        drawWidgetLines(encoder: encoder, vertices: &ruler, viewProjection: vp,
                        color: SIMD4<Float>(0.55, 0.6, 0.7, 1.0))
    }

    /// Draws the bake probe as an RGB axis-cross gizmo at its world position.
    /// Live viewport only (the exporter never calls this), so it stays out of renders.
    private func drawProbeGizmo(encoder: MTLRenderCommandEncoder) {
        guard let probe = probeConfig, probe.isVisible,
              let pipeline = widgetPipelineState else { return }

        encoder.setRenderPipelineState(pipeline)
        if let ds = laserBeamDepthState { encoder.setDepthStencilState(ds) }
        encoder.setCullMode(.none)

        let vp  = viewCamera.viewProjectionMatrix
        let p   = probe.position
        let len = max(0.4, min(camera.distance * 0.25, 1.5))   // readable axis length

        var xAxis = [p - SIMD3<Float>(len, 0, 0), p + SIMD3<Float>(len, 0, 0)]
        drawWidgetLines(encoder: encoder, vertices: &xAxis, viewProjection: vp,
                        color: SIMD4<Float>(1.0, 0.25, 0.25, 1.0))
        var yAxis = [p - SIMD3<Float>(0, len, 0), p + SIMD3<Float>(0, len, 0)]
        drawWidgetLines(encoder: encoder, vertices: &yAxis, viewProjection: vp,
                        color: SIMD4<Float>(0.30, 1.0, 0.30, 1.0))
        var zAxis = [p - SIMD3<Float>(0, 0, len), p + SIMD3<Float>(0, 0, len)]
        drawWidgetLines(encoder: encoder, vertices: &zAxis, viewProjection: vp,
                        color: SIMD4<Float>(0.35, 0.55, 1.0, 1.0))

        var sphere = SceneWidgets.sphereWireframe(center: p, radius: len * 0.18)
        drawWidgetLines(encoder: encoder, vertices: &sphere, viewProjection: vp,
                        color: SIMD4<Float>(1.0, 1.0, 1.0, 1.0))
    }

    /// Draws the keyframe motion path for the selected entity (the 'V' overlay):
    /// a light-grey poly-line through the keyframe world positions in time order,
    /// with a small red cross marking each keyframe.  Editor-only; never exported.
    private func drawMotionVectors(encoder: MTLRenderCommandEncoder) {
        guard motionVectorTarget != .none,
              let pipeline = widgetPipelineState else { return }

        let points = motionVectorPoints()
        guard points.count >= 1 else { return }

        encoder.setRenderPipelineState(pipeline)
        if let ds = laserBeamDepthState { encoder.setDepthStencilState(ds) }
        encoder.setCullMode(.none)
        let vp = viewCamera.viewProjectionMatrix

        // Connecting path (light grey) — needs at least two points.
        if points.count >= 2 {
            var path: [SIMD3<Float>] = []
            for i in 0..<(points.count - 1) {
                path.append(points[i]); path.append(points[i + 1])
            }
            drawWidgetLines(encoder: encoder, vertices: &path, viewProjection: vp,
                            color: SIMD4<Float>(0.75, 0.75, 0.75, 1.0))
        }

        // Red cross marker at each keyframe, sized for on-screen readability.
        let s = max(0.05, min(camera.distance * 0.02, 0.4))
        var marks: [SIMD3<Float>] = []
        for p in points {
            marks.append(p - SIMD3<Float>(s, 0, 0)); marks.append(p + SIMD3<Float>(s, 0, 0))
            marks.append(p - SIMD3<Float>(0, s, 0)); marks.append(p + SIMD3<Float>(0, s, 0))
            marks.append(p - SIMD3<Float>(0, 0, s)); marks.append(p + SIMD3<Float>(0, 0, s))
        }
        drawWidgetLines(encoder: encoder, vertices: &marks, viewProjection: vp,
                        color: SIMD4<Float>(1.0, 0.2, 0.2, 1.0))
    }

    /// World-space keyframe positions for the current `motionVectorTarget`,
    /// sorted in time order.
    private func motionVectorPoints() -> [SIMD3<Float>] {
        switch motionVectorTarget {
        case .none:
            return []

        case .camera:
            guard let track = camera.keyframeTrack, !track.keyframes.isEmpty else { return [] }
            // Eye position = target + spherical offset from yaw/pitch/distance.
            return track.keyframes.sorted { $0.time < $1.time }.map { kf in
                SIMD3<Float>(
                    kf.target.x + kf.distance * cos(kf.pitch) * sin(kf.yaw),
                    kf.target.y + kf.distance * sin(kf.pitch),
                    kf.target.z + kf.distance * cos(kf.pitch) * cos(kf.yaw))
            }

        case .light:
            let idx = lightManager.selectedIndex
            guard idx < lightManager.keyframeTracks.count,
                  let track = lightManager.keyframeTracks[idx],
                  !track.keyframes.isEmpty else { return [] }
            return track.keyframes.sorted { $0.time < $1.time }.map { $0.position }

        case .object:
            guard let obj = sceneManager.selectedObject else { return [] }
            // Group-animated model: the group track drives world motion.
            if let gid = obj.groupID, let gTrack = sceneManager.groupKeyframeTracks[gid],
               !gTrack.keyframes.isEmpty {
                return gTrack.keyframes.sorted { $0.time < $1.time }.map { kf in
                    let m = gTrack.evaluate(at: kf.time) ?? matrix_identity_float4x4
                    return SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
                }
            }
            // Per-object track: world point = (group? × baseTransform × delta).t
            guard let track = obj.keyframeTrack, !track.keyframes.isEmpty else { return [] }
            let groupMat: matrix_float4x4 = obj.groupID
                .flatMap { sceneManager.groupTransforms[$0] } ?? matrix_identity_float4x4
            return track.keyframes.sorted { $0.time < $1.time }.map { kf in
                let delta = track.evaluate(at: kf.time) ?? matrix_identity_float4x4
                let world = groupMat * obj.baseTransform * delta
                return SIMD3<Float>(world.columns.3.x, world.columns.3.y, world.columns.3.z)
            }
        }
    }

    /// Helper: uploads a line-segment vertex list (every pair = one segment)
    /// and uniform colour, then issues a single line-list draw call.
    /// Vertex data uses setVertexBytes (small, regenerated each frame).
    private func drawWidgetLines(encoder:        MTLRenderCommandEncoder,
                                 vertices:       inout [SIMD3<Float>],
                                 viewProjection: matrix_float4x4,
                                 color:          SIMD4<Float>) {
        guard !vertices.isEmpty else { return }
        let byteCount = MemoryLayout<SIMD3<Float>>.stride * vertices.count
        encoder.setVertexBytes(&vertices, length: byteCount, index: 0)

        var u = WidgetUniforms(viewProjectionMatrix: viewProjection, color: color)
        encoder.setVertexBytes(&u, length: MemoryLayout<WidgetUniforms>.stride, index: 1)

        encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: vertices.count)
    }

    // MARK: - Animation evaluation

    /// Forces `applyAnimation()` to run on the very next draw call, regardless of
    /// whether `currentTime` has changed.  Call this after restoring keyframe tracks
    /// from a project file — without it, the t=0 pose may not be applied because
    /// `lastAnimatedTime` already equals `currentTime` (both are 0).
    func invalidateAnimationCache() {
        lastAnimatedTime = -1.0
        lastAtmoSyncTime = -1.0   // also re-sync the atmosphere panel/render to the playhead
        print("[DEBUG] Renderer: animation cache invalidated — will re-evaluate on next draw")
    }

    private func applyAnimation() {
        // ── Object transforms ─────────────────────────────────────────────────
        for object in sceneManager.objects {
            guard let track = object.keyframeTrack,
                  !track.keyframes.isEmpty else { continue }
            if let delta = track.evaluate(at: timeline.renderTime) {
                if object.parentIndex != nil {
                    // Hierarchical part: baseTransform is a LOCAL transform, so
                    // the animated result goes into localTransform.
                    // applyHierarchy() (called every frame) computes world transform.
                    object.localTransform = object.baseTransform * delta
                } else {
                    // Root / non-hierarchical: animate world transform directly.
                    object.transform = object.baseTransform * delta
                }
            }
            // Opacity rides on the same keyframes — sample it here so the
            // animated value reaches the renderer through material.opacity.
            // No track keyframes ⇒ no write, so the Inspector slider's static
            // value is preserved on un-animated objects.
            if let op = track.evaluateOpacity(at: timeline.renderTime) {
                object.material.opacity = op
            }
        }

        // ── Group-level transforms (Phase 2) ──────────────────────────────────
        // Evaluate each group's keyframe track and store the result in
        // sceneManager.groupTransforms so the render loop can apply it.
        for (gid, track) in sceneManager.groupKeyframeTracks {
            guard !track.keyframes.isEmpty else { continue }
            if let delta = track.evaluate(at: timeline.renderTime) {
                sceneManager.groupTransforms[gid] = delta
            }
        }

        // ── Camera (base evaluation) ──────────────────────────────────────────
        // The follow override is applied separately in applyCameraFollow(), called
        // after applyHierarchy() so sub-part world transforms are fully up-to-date.
        if let camTrack = camera.keyframeTrack, !camTrack.keyframes.isEmpty {
            if let state = camTrack.evaluate(at: timeline.renderTime) {
                camera.yaw         = state.yaw
                camera.pitch       = state.pitch
                camera.distance    = state.distance
                camera.target      = state.target
                camera.fovYRadians = state.fov
            }
        }

        // ── Lights ────────────────────────────────────────────────────────────
        // While PLAYING, evaluate into the non-published `animatedLights` copy so
        // the Lights inspector (heavy SwiftUI panel) doesn't re-render every frame.
        // While paused/scrubbing, write @Published lightManager.lights so the
        // inspector follows the playhead.  (draw() mirrors lightManager.lights into
        // animatedLights every paused frame, and publishes the final state on the
        // play→pause transition.)
        if timeline.isPlaying {
            if animatedLights.count != lightManager.lights.count {
                animatedLights = lightManager.lights
            }
            for i in 0..<lightManager.lights.count {
                animatedLights[i] = lightManager.lights[i]   // base = editor values
                guard i < lightManager.keyframeTracks.count,
                      let track = lightManager.keyframeTracks[i],
                      !track.keyframes.isEmpty,
                      let state = track.evaluate(at: timeline.renderTime) else { continue }
                animatedLights[i].intensity     = state.intensity
                animatedLights[i].color         = state.color
                animatedLights[i].position      = state.position
                animatedLights[i].target        = state.target
                animatedLights[i].range         = state.range
                animatedLights[i].beamThickness = state.beamThickness
            }
        } else {
            for i in 0..<lightManager.lights.count {
                guard i < lightManager.keyframeTracks.count,
                      let track = lightManager.keyframeTracks[i],
                      !track.keyframes.isEmpty,
                      let state = track.evaluate(at: timeline.renderTime) else { continue }
                lightManager.lights[i].intensity     = state.intensity
                lightManager.lights[i].color         = state.color
                lightManager.lights[i].position      = state.position
                lightManager.lights[i].target        = state.target
                lightManager.lights[i].range         = state.range
                lightManager.lights[i].beamThickness = state.beamThickness
            }
        }
    }

    // MARK: - FK Hierarchy propagation

    /// Recomputes world transforms for all hierarchical parts in depth-first order.
    /// GLTFLoader guarantees parents come before children in the objects array,
    /// so a single forward pass is sufficient.
    /// Non-hierarchical parts (parentIndex == nil) are skipped — their `transform`
    /// is driven by applyAnimation() or direct interaction, unchanged.
    private func applyHierarchy() {
        let objects = sceneManager.objects
        for obj in objects {
            guard let parentIdx = obj.parentIndex,
                  parentIdx < objects.count else { continue }
            obj.transform = objects[parentIdx].transform * obj.localTransform
        }
    }

    /// Applies the camera-follow override using the world transforms that were
    /// just computed by applyHierarchy().  Must be called every frame after
    /// applyHierarchy() — NOT inside applyAnimation() — so that sub-part
    /// transforms (e.g. a head bone) are fully propagated before they are read.
    private func applyCameraFollow() {
        // Suspended only while actively editing a camera-follow keyframe (set by
        // AppDelegate on edit entry, cleared on commit/cancel) so the user's live
        // adjustments to target/yaw aren't overwritten each frame.  Otherwise follow
        // stays live in every mode — including camera mode while paused — so
        // SCRUBBING accurately previews where the follow camera will be at each
        // frame, matching playback.  (A broad camera-mode-and-paused guard used to
        // live here too, but it also blocked plain scrubbing in camera mode.)
        guard !camera.followSuspended else { return }
        guard let camTrack = camera.keyframeTrack,
              !camTrack.keyframes.isEmpty else { return }
        if let follow = camTrack.resolveFollowCamera(
            at:             timeline.renderTime,
            getObjectState: { [weak self] name in
                self?.sceneManager.worldOrbitAnchor(ofObjectNamed: name)
            }
        ) {
            camera.target = follow.target
            if let yaw   = follow.yaw   { camera.yaw   = yaw }
            if let pitch = follow.pitch {
                // Clamp to avoid gimbal lock at the poles — same window the
                // existing camera operations use when writing pitch directly.
                camera.pitch = max(-Float.pi / 2 + 0.01,
                                min( Float.pi / 2 - 0.01, pitch))
            }
            // worldUp non-nil = POV keyframe asked the camera to roll with the
            // followed object.  Renormalize defensively in case the inter-segment
            // lerp produced a near-axis vector.
            if let up = follow.worldUp {
                let len = simd_length(up)
                camera.followUpOverride = len > 1e-4 ? up / len : nil
            } else {
                camera.followUpOverride = nil
            }
        }
    }
}
