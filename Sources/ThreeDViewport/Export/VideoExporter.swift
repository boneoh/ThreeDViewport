import Foundation
import Metal
import AVFoundation
import CoreVideo

// Phase 3: Exports the animated scene to a ProRes .mov file at 1920×1080.
//
// Architecture:
//   • Renders each frame offscreen to a private MTLTexture (GPU only).
//   • Blits to a CPU-readable staging texture (managed / shared storage).
//   • Reads pixels via getBytes into a CVPixelBuffer.
//   • Appends each buffer to AVAssetWriter at the correct presentation time.
//
// IMPORTANT: The MTKView render loop must be paused (isPaused = true) before
// calling export(to:...) to prevent transform race conditions on SceneObjects.

// Export resolution presets shown in the export panel.
struct ExportResolution: Equatable {
    let display: String
    let width:   Int
    let height:  Int

    static let presets: [ExportResolution] = [
        ExportResolution(display: "720 × 480",   width: 720,  height: 480),
        ExportResolution(display: "720 × 576",   width: 720,  height: 576),
        ExportResolution(display: "1280 × 720",  width: 1280, height: 720),
        ExportResolution(display: "1920 × 1080", width: 1920, height: 1080),
    ]

    /// The preset matching w×h, or 1920×1080 if none match.
    static func matching(width w: Int, height h: Int) -> ExportResolution {
        presets.first { $0.width == w && $0.height == h } ?? presets[3]
    }
}

// Export frame-rate presets.  Rational timescale/duration keeps NTSC rates exact
// (e.g. 29.97 = 30000/1001), which a plain CMTimeScale(Double) would truncate.
struct ExportFrameRate: Equatable {
    let display:       String
    let value:         Double   // fps as a Double (animation sampling, totalFrames)
    let timescale:     Int32    // CMTime timescale
    let frameDuration: Int32    // CMTime value advanced per frame

    static let presets: [ExportFrameRate] = [
        ExportFrameRate(display: "23.976", value: 24000.0 / 1001.0, timescale: 24000, frameDuration: 1001),
        ExportFrameRate(display: "24",     value: 24.0,             timescale: 24000, frameDuration: 1000),
        ExportFrameRate(display: "25",     value: 25.0,             timescale: 25000, frameDuration: 1000),
        ExportFrameRate(display: "29.97",  value: 30000.0 / 1001.0, timescale: 30000, frameDuration: 1001),
        ExportFrameRate(display: "30",     value: 30.0,             timescale: 30000, frameDuration: 1000),
        ExportFrameRate(display: "50",     value: 50.0,             timescale: 50000, frameDuration: 1000),
        ExportFrameRate(display: "59.94",  value: 60000.0 / 1001.0, timescale: 60000, frameDuration: 1001),
        ExportFrameRate(display: "60",     value: 60.0,             timescale: 60000, frameDuration: 1000),
    ]

    /// The preset whose value is closest to `fps` (used to preselect from the project rate).
    static func closest(to fps: Double) -> ExportFrameRate {
        presets.min { abs($0.value - fps) < abs($1.value - fps) } ?? presets[4]
    }
}

// Codec choice presented to the user in the NSSavePanel accessory view.
enum ExportCodec {

    /// ProRes 4444 — 12-bit RGB + alpha channel.
    /// Alpha = Luma is baked in (Rec.709), so black → transparent and
    /// bright areas → opaque.  Ready for direct use in DaVinci Resolve
    /// and LZX Videomancer without a separate key pass.
    case proRes4444

    /// ProRes 422 HQ — 10-bit 4:2:2, no alpha.
    /// Highest-quality 422 variant; standard professional codec for CG
    /// renders going into colour-grading pipelines.  Pure black background.
    case proRes422HQ

    var displayName: String {
        switch self {
        case .proRes4444:  return "ProRes 4444 — Alpha = Luma (compositing)"
        case .proRes422HQ: return "ProRes 422 HQ — solid black (grading)"
        }
    }

    var avCodecType: AVVideoCodecType {
        switch self {
        case .proRes4444:  return .proRes4444
        case .proRes422HQ: return .proRes422HQ
        }
    }

    /// True only for 4444 — the luma-alpha CPU pass is skipped for 422.
    var needsLumaAlpha: Bool { self == .proRes4444 }

    /// Stable string identifier for settings persistence.
    var id: String {
        switch self {
        case .proRes4444:  return "proRes4444"
        case .proRes422HQ: return "proRes422HQ"
        }
    }

    static func from(id: String) -> ExportCodec {
        id == "proRes422HQ" ? .proRes422HQ : .proRes4444
    }
}

final class VideoExporter {

    // MARK: - Export resolution (from AppSettings; camera aspect is matched at export)

    let width:  Int = AppSettings.shared.exportWidth
    let height: Int = AppSettings.shared.exportHeight

    // MARK: - Private dependencies

    private let device:            MTLDevice
    private let commandQueue:      MTLCommandQueue
    private let sceneManager:      SceneManager
    private let camera:            CameraController
    private let lightManager:      LightManager
    private let backgroundConfig:  BackgroundConfig
    private let pipelineState:     MTLRenderPipelineState
    private let depthStencilState: MTLDepthStencilState
    // Holdout (depth-only) pipeline — shared from the Renderer so exports occlude
    // identically to the preview.  nil disables the holdout pass.
    private let holdoutPipelineState: MTLRenderPipelineState?
    // Transparent (alpha-blended, no depth write) pipeline + matching depth state.
    // Shared from the Renderer.  nil = transparent pass skipped (export will draw
    // opacity<1 parts opaquely, matching pre-feature behaviour).
    private let transparentPipelineState: MTLRenderPipelineState?
    private let transparentDepthState:    MTLDepthStencilState?
    private let animDuration:      Double
    private let frameRate:         Double
    private let frameTimescale:    Int32   // CMTime timescale (rational, exact for NTSC)
    private let frameTicks:        Int32   // CMTime value advanced per frame

    // Phase 8+: rendering options matching the live display
    var colorMode:     RenderColorMode = .color
    var isWireframe:   Bool = false
    var showAxesGizmo: Bool = false

    // Background gradient pipeline (mirrors Renderer's background pipeline)
    private var backgroundPipelineState: MTLRenderPipelineState?
    private var backgroundDepthState:    MTLDepthStencilState?
    // Environment skybox pipeline (mirrors Renderer's skybox pipeline)
    private var skyboxPipelineState:     MTLRenderPipelineState?
    private var dummyEquirect:           MTLTexture?
    /// Dedicated background HDR equirect, shared from the Renderer so export matches.
    var backgroundEquirect:              MTLTexture?

    // Feedback settings — nil means no feedback during export
    var feedbackSettings: FeedbackSettings?

    // Color grade settings — nil or identity = no grade pass during export
    var colorGradeSettings: ColorGradeSettings?

    // Fog settings — nil = no fog during export
    var fogSettings: FogSettings?
    private var fogVolumePipelineState: MTLRenderPipelineState?

    // Weather particles — nil/empty = none during export
    var particleManager: ParticleManager?
    private var particleFXPipelineState: MTLRenderPipelineState?
    private var particleSeedBuffer:      MTLBuffer?

    // Phase C: image-based lighting — shared with the live Renderer so exports
    // match the viewport.  Set by ViewportView after construction.
    var ibl: IBL?

    // Fallback buffers for objects without UVs / tangents
    private var dummyUVBuffer:      MTLBuffer?
    private var dummyTangentBuffer: MTLBuffer?

    // Gizmo pipeline — built lazily from the same Metal library as the scene pipeline
    private var gizmoPipelineState: MTLRenderPipelineState?

    // Laser beam billboard pipeline (additive blend, depth test without write)
    private var laserBeamPipelineState: MTLRenderPipelineState?
    private var laserBeamDepthState:    MTLDepthStencilState?

    // Laser hit effect pipeline
    private var laserHitPipelineState:  MTLRenderPipelineState?

    // Spark particle pipeline (additive, instanced billboards)
    private var sparkPipelineState:     MTLRenderPipelineState?

    // Color grade pipeline (fullscreen B/C post-process)
    private var colorGradePipelineState: MTLRenderPipelineState?

    // Laser hit system — independent of the live renderer, reset per export
    private var laserHitSystem: LaserHitSystem = LaserHitSystem()

    // MARK: - Init

    init?(device:            MTLDevice,
          commandQueue:      MTLCommandQueue,
          sceneManager:      SceneManager,
          camera:            CameraController,
          lightManager:      LightManager,
          backgroundConfig:  BackgroundConfig,
          timeline:          Timeline,
          fps:               ExportFrameRate,
          pipelineState:     MTLRenderPipelineState,
          depthStencilState: MTLDepthStencilState,
          holdoutPipelineState: MTLRenderPipelineState? = nil,
          transparentPipelineState: MTLRenderPipelineState? = nil,
          transparentDepthState:    MTLDepthStencilState?   = nil) {

        self.device            = device
        self.commandQueue      = commandQueue
        self.sceneManager      = sceneManager
        self.camera            = camera
        self.lightManager      = lightManager
        self.backgroundConfig  = backgroundConfig
        self.pipelineState     = pipelineState
        self.depthStencilState = depthStencilState
        self.holdoutPipelineState     = holdoutPipelineState
        self.transparentPipelineState = transparentPipelineState
        self.transparentDepthState    = transparentDepthState
        self.animDuration      = timeline.duration
        self.frameRate         = fps.value
        self.frameTimescale    = fps.timescale
        self.frameTicks        = fps.frameDuration

        // Dummy buffers for objects without UV / tangent data
        var dummyUV:  [Float] = [0, 0]
        var dummyTan: [Float] = [1, 0, 0, 1]
        dummyUVBuffer = device.makeBuffer(bytes: &dummyUV,
                                          length: 2 * MemoryLayout<Float>.stride,
                                          options: .storageModeShared)
        dummyTangentBuffer = device.makeBuffer(bytes: &dummyTan,
                                               length: 4 * MemoryLayout<Float>.stride,
                                               options: .storageModeShared)

        // Background gradient pipeline — same shaders as the live renderer
        if let library  = try? device.makeDefaultLibrary(bundle: Bundle.module),
           let bgV      = library.makeFunction(name: "background_vertex"),
           let bgF      = library.makeFunction(name: "background_fragment") {
            let bgDesc = MTLRenderPipelineDescriptor()
            bgDesc.label            = "BackgroundExport"
            bgDesc.vertexFunction   = bgV
            bgDesc.fragmentFunction = bgF
            bgDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
            bgDesc.depthAttachmentPixelFormat      = .depth32Float
            backgroundPipelineState = try? device.makeRenderPipelineState(descriptor: bgDesc)

            let bgDepthDesc = MTLDepthStencilDescriptor()
            bgDepthDesc.depthCompareFunction = .always
            bgDepthDesc.isDepthWriteEnabled  = false
            backgroundDepthState = device.makeDepthStencilState(descriptor: bgDepthDesc)

            if backgroundPipelineState != nil {
                print("[DEBUG] VideoExporter: background pipeline created")
            } else {
                print("[DEBUG] VideoExporter: background pipeline makeRenderPipelineState failed")
            }

            // Environment skybox pipeline — mirrors the live renderer so export matches.
            if let skyV = library.makeFunction(name: "skybox_vertex"),
               let skyF = library.makeFunction(name: "skybox_fragment") {
                let skyDesc = MTLRenderPipelineDescriptor()
                skyDesc.label            = "SkyboxExport"
                skyDesc.vertexFunction   = skyV
                skyDesc.fragmentFunction = skyF
                skyDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
                skyDesc.depthAttachmentPixelFormat      = .depth32Float
                skyboxPipelineState = try? device.makeRenderPipelineState(descriptor: skyDesc)
            }
            let dDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
            dDesc.usage = [.shaderRead]
            dummyEquirect = device.makeTexture(descriptor: dDesc)
        } else {
            print("[DEBUG] VideoExporter: background shaders not found in bundle")
        }

        // Gizmo pipeline — same shaders as the live renderer
        if let library  = try? device.makeDefaultLibrary(bundle: Bundle.module),
           let gizmoV   = library.makeFunction(name: "gizmo_vertex"),
           let gizmoF   = library.makeFunction(name: "gizmo_fragment") {
            let gizmoDesc = MTLRenderPipelineDescriptor()
            gizmoDesc.label            = "GizmoExport"
            gizmoDesc.vertexFunction   = gizmoV
            gizmoDesc.fragmentFunction = gizmoF
            let gCA = gizmoDesc.colorAttachments[0]!
            gCA.pixelFormat                 = .bgra8Unorm
            gCA.isBlendingEnabled           = true
            gCA.sourceRGBBlendFactor        = .sourceAlpha
            gCA.destinationRGBBlendFactor   = .oneMinusSourceAlpha
            gCA.sourceAlphaBlendFactor      = .one
            gCA.destinationAlphaBlendFactor = .zero
            gizmoPipelineState = try? device.makeRenderPipelineState(descriptor: gizmoDesc)
            if gizmoPipelineState != nil {
                print("[DEBUG] VideoExporter: gizmo pipeline created")
            } else {
                print("[DEBUG] VideoExporter: gizmo pipeline makeRenderPipelineState failed")
            }
        } else {
            print("[DEBUG] VideoExporter: gizmo shaders not found in bundle")
        }

        // Laser beam billboard pipeline
        if let library  = try? device.makeDefaultLibrary(bundle: Bundle.module),
           let laserV   = library.makeFunction(name: "laser_beam_vertex"),
           let laserF   = library.makeFunction(name: "laser_beam_fragment") {
            let laserDesc = MTLRenderPipelineDescriptor()
            laserDesc.label                           = "LaserBeamExport"
            laserDesc.vertexFunction                  = laserV
            laserDesc.fragmentFunction                = laserF
            laserDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
            laserDesc.depthAttachmentPixelFormat      = .depth32Float
            let laserCA = laserDesc.colorAttachments[0]!
            laserCA.isBlendingEnabled           = true
            laserCA.sourceRGBBlendFactor        = .one
            laserCA.destinationRGBBlendFactor   = .one
            laserCA.rgbBlendOperation           = .add
            laserCA.sourceAlphaBlendFactor      = .zero
            laserCA.destinationAlphaBlendFactor = .one
            laserCA.alphaBlendOperation         = .add
            laserBeamPipelineState = try? device.makeRenderPipelineState(descriptor: laserDesc)
            let laserDepthDesc = MTLDepthStencilDescriptor()
            laserDepthDesc.depthCompareFunction = .lessEqual
            laserDepthDesc.isDepthWriteEnabled  = false
            laserBeamDepthState = device.makeDepthStencilState(descriptor: laserDepthDesc)
            print("[DEBUG] VideoExporter: laser beam pipeline "
                + (laserBeamPipelineState != nil ? "created" : "FAILED"))
        }

        // Laser hit effect pipeline
        if let library = try? device.makeDefaultLibrary(bundle: Bundle.module),
           let hitV    = library.makeFunction(name: "laser_hit_vertex"),
           let hitF    = library.makeFunction(name: "laser_hit_fragment") {
            let hitDesc = MTLRenderPipelineDescriptor()
            hitDesc.label            = "LaserHitExport"
            hitDesc.vertexFunction   = hitV
            hitDesc.fragmentFunction = hitF
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
            laserHitPipelineState = try? device.makeRenderPipelineState(descriptor: hitDesc)
            print("[DEBUG] VideoExporter: laser hit pipeline "
                + (laserHitPipelineState != nil ? "created" : "FAILED"))
        }

        // Spark particle pipeline
        if let library  = try? device.makeDefaultLibrary(bundle: Bundle.module),
           let sparkV   = library.makeFunction(name: "spark_vertex"),
           let sparkF   = library.makeFunction(name: "spark_fragment") {
            let sparkDesc = MTLRenderPipelineDescriptor()
            sparkDesc.label            = "SparkExport"
            sparkDesc.vertexFunction   = sparkV
            sparkDesc.fragmentFunction = sparkF
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
            sparkPipelineState = try? device.makeRenderPipelineState(descriptor: sparkDesc)
            print("[DEBUG] VideoExporter: spark pipeline "
                + (sparkPipelineState != nil ? "created" : "FAILED"))
        }

        // Weather particle pipeline (instanced billboards, alpha blend)
        if let library = try? device.makeDefaultLibrary(bundle: Bundle.module),
           let pVert   = library.makeFunction(name: "particlefx_vertex"),
           let pFrag   = library.makeFunction(name: "particlefx_fragment") {
            let pDesc = MTLRenderPipelineDescriptor()
            pDesc.label                           = "ParticleFXExport"
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
            particleFXPipelineState = try? device.makeRenderPipelineState(descriptor: pDesc)
            print("[DEBUG] VideoExporter: particle pipeline "
                + (particleFXPipelineState != nil ? "created" : "FAILED"))
        }
        // Static deterministic seed pool (identical to the live renderer's).
        let pSeeds = ParticleEffect.makeSeeds()
        particleSeedBuffer = device.makeBuffer(bytes: pSeeds,
                                               length: pSeeds.count * MemoryLayout<SIMD4<Float>>.stride,
                                               options: .storageModeShared)

        // Fog volume pipeline (fullscreen raymarch, source-over blend)
        if let library = try? device.makeDefaultLibrary(bundle: Bundle.module),
           let fVert   = library.makeFunction(name: "fogvolume_vertex"),
           let fFrag   = library.makeFunction(name: "fogvolume_fragment") {
            let fDesc = MTLRenderPipelineDescriptor()
            fDesc.label            = "FogVolumeExport"
            fDesc.vertexFunction   = fVert
            fDesc.fragmentFunction = fFrag
            let ca = fDesc.colorAttachments[0]!
            ca.pixelFormat                 = .bgra8Unorm
            ca.isBlendingEnabled           = true
            ca.sourceRGBBlendFactor        = .sourceAlpha
            ca.destinationRGBBlendFactor   = .oneMinusSourceAlpha
            ca.rgbBlendOperation           = .add
            ca.sourceAlphaBlendFactor      = .one
            ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            ca.alphaBlendOperation         = .add
            fogVolumePipelineState = try? device.makeRenderPipelineState(descriptor: fDesc)
            print("[DEBUG] VideoExporter: fog volume pipeline "
                + (fogVolumePipelineState != nil ? "created" : "FAILED"))
        }

        // Color grade pipeline (no depth, no blend — overwrites every pixel)
        if let library    = try? device.makeDefaultLibrary(bundle: Bundle.module),
           let gradeVertFn = library.makeFunction(name: "color_grade_vertex"),
           let gradeFragFn = library.makeFunction(name: "color_grade_fragment") {
            let gradeDesc = MTLRenderPipelineDescriptor()
            gradeDesc.label                           = "ColorGradeExport"
            gradeDesc.vertexFunction                  = gradeVertFn
            gradeDesc.fragmentFunction                = gradeFragFn
            gradeDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
            colorGradePipelineState = try? device.makeRenderPipelineState(descriptor: gradeDesc)
            print("[DEBUG] VideoExporter: color grade pipeline "
                + (colorGradePipelineState != nil ? "created" : "FAILED"))
        }

        print("[DEBUG] VideoExporter: initialized — duration="
            + String(format: "%.1f", timeline.duration)
            + "s frameRate=" + String(format: "%.0f", timeline.frameRate)
            + " totalFrames=" + String(Int(timeline.duration * timeline.frameRate)))
    }

    // MARK: - Public export entry point

    /// Exports the full animation to a ProRes .mov at the given URL.
    /// `codec` selects ProRes 4444 (with Alpha=Luma) or ProRes 422 HQ (solid black).
    /// `progress` is called on the main thread with values 0.0–1.0.
    /// `completion` is called on the main thread; nil = success, otherwise Error.
    func export(to url: URL,
                codec:      ExportCodec,
                progress:   @escaping (Float)   -> Void,
                completion: @escaping (Error?)  -> Void) {

        let totalFrames = Int(animDuration * frameRate)
        guard totalFrames > 0 else {
            print("[DEBUG] VideoExporter: export — totalFrames is zero, aborting")
            DispatchQueue.main.async { completion(ExportError.zeroDuration) }
            return
        }

        print("[DEBUG] VideoExporter: export start — "
            + String(totalFrames) + " frames → " + url.lastPathComponent)

        // ── Create offscreen Metal textures ───────────────────────────────────
        guard let colorTex   = makeColorTexture(),
              let stagingTex = makeStagingTexture(),
              let depthTex   = makeDepthTexture() else {
            DispatchQueue.main.async { completion(ExportError.textureCreationFailed) }
            return
        }
        // Grade intermediate — same size as colorTex; only allocated when needed
        let gradeTex: MTLTexture? = {
            guard let settings = colorGradeSettings, !settings.isIdentity else { return nil }
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            desc.usage       = [.shaderRead, .renderTarget]
            desc.storageMode = .private
            return device.makeTexture(descriptor: desc)
        }()

        // ── Feedback processor (independent of the live viewport) ─────────────
        // Created here so export feedback is isolated; always resets from scratch.
        var exportFeedback: FeedbackProcessor? = nil
        if let fs = feedbackSettings, fs.isEnabled {
            let fp = FeedbackProcessor(device: device)
            fp.resize(width: width, height: height, length: fs.length)
            fp.reset()
            exportFeedback = fp
            print("[DEBUG] VideoExporter: feedback enabled — interval=\(fs.interval)"
                + " decay=\(String(format:"%.2f",fs.decay)) length=\(fs.length)")
        }

        // ── Set up AVAssetWriter ──────────────────────────────────────────────
        try? FileManager.default.removeItem(at: url)  // overwrite if exists

        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
            print("[DEBUG] VideoExporter: AVAssetWriter init failed for " + url.path)
            DispatchQueue.main.async { completion(ExportError.writerCreationFailed) }
            return
        }

        // Build video settings for the chosen codec.
        // ProRes 4444 is RGB-based — no AVVideoYCbCrMatrixKey.
        // ProRes 422 HQ is YCbCr-based — include full Rec.709 colour properties.
        let videoSettings: [String: Any]
        switch codec {
        case .proRes4444:
            videoSettings = [
                AVVideoCodecKey:  AVVideoCodecType.proRes4444,
                AVVideoWidthKey:  NSNumber(value: width),
                AVVideoHeightKey: NSNumber(value: height)
            ]
        case .proRes422HQ:
            videoSettings = [
                AVVideoCodecKey:  AVVideoCodecType.proRes422HQ,
                AVVideoWidthKey:  NSNumber(value: width),
                AVVideoHeightKey: NSNumber(value: height),
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey:   AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey:      AVVideoYCbCrMatrix_ITU_R_709_2
                ] as [String: Any]
            ]
        }

        print("[DEBUG] VideoExporter: codec=" + codec.displayName)

        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            print("[DEBUG] VideoExporter: canApply returned false — codec not supported on this Mac")
            DispatchQueue.main.async { completion(ExportError.codecNotSupported) }
            return
        }

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false

        // kCVPixelBufferMetalCompatibilityKey is omitted — we use CPU getBytes readback,
        // not a Metal-backed IOSurface pixel buffer, so the flag is unnecessary.
        let pbAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey           as String: width,
            kCVPixelBufferHeightKey          as String: height
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: pbAttrs
        )

        guard writer.canAdd(writerInput) else {
            print("[DEBUG] VideoExporter: writer.canAdd returned false")
            DispatchQueue.main.async { completion(ExportError.cannotAddInput) }
            return
        }
        writer.add(writerInput)

        // ── Run export loop on a background queue ─────────────────────────────
        let exportQ = DispatchQueue(label: "com.threedviewport.videoexport", qos: .userInitiated)
        // Strong capture [self] keeps the VideoExporter alive until the closure finishes.
        // VideoExporter is short-lived (no back-references), so there is no retain cycle.
        exportQ.async { [self] in

            writer.startWriting()

            // Fail fast: if startWriting put the writer into .failed state, surface the error now.
            if writer.status == .failed {
                let msg = writer.error?.localizedDescription ?? "unknown"
                print("[DEBUG] VideoExporter: startWriting FAILED — " + msg)
                DispatchQueue.main.async { completion(writer.error ?? ExportError.writerCreationFailed) }
                return
            }

            writer.startSession(atSourceTime: .zero)
            print("[DEBUG] VideoExporter: writer started, status=" + String(writer.status.rawValue))

            for frameIndex in 0..<totalFrames {
                // Rational timing — exact for NTSC rates (e.g. 30000/1001).
                let presentationTime = CMTime(value: CMTimeValue(frameIndex) * CMTimeValue(self.frameTicks),
                                              timescale: self.frameTimescale)
                let t = Double(frameIndex) * Double(self.frameTicks) / Double(self.frameTimescale)

                // Evaluate animation at this exact time — does NOT touch Timeline.currentTime
                self.applyAnimation(at: t)

                // Laser hit detection + particle simulation (deterministic, uses frame time)
                let frameDt     = Float(1.0 / self.frameRate)
                let frameHitTime = Float(t)
                let visibleObjs  = self.sceneManager.objects.filter { $0.isVisible }
                self.laserHitSystem.updateHits(lights: self.lightManager.lights,
                                               objects: visibleObjs)
                self.laserHitSystem.updateParticles(dt: frameDt)
                let sparkGPUData = self.laserHitSystem.buildSparkGPUData()

                // Render to offscreen texture (via feedback if enabled) and blit to staging
                self.renderFrame(colorTex:        colorTex,
                                 stagingTex:       stagingTex,
                                 depthTex:         depthTex,
                                 gradeTex:         gradeTex,
                                 feedbackProc:     exportFeedback,
                                 feedbackSettings: self.feedbackSettings,
                                 hitEffectTime:    frameHitTime,
                                 sparkGPUData:     sparkGPUData)

                // Copy staging texture → CVPixelBuffer (luma-alpha applied for 4444)
                guard let pb = self.pixelBufferFrom(stagingTex,
                                                    pool: adaptor.pixelBufferPool,
                                                    applyLumaAlpha: codec.needsLumaAlpha) else {
                    print("[DEBUG] VideoExporter: frame " + String(frameIndex)
                        + " — pixel buffer creation failed, skipping")
                    continue
                }

                // Wait until AVAssetWriterInput is ready (should be near-instant)
                var waitCount = 0
                while !writerInput.isReadyForMoreMediaData {
                    Thread.sleep(forTimeInterval: 0.002)
                    waitCount += 1
                    if waitCount > 500 {
                        print("[DEBUG] VideoExporter: frame " + String(frameIndex)
                            + " — input not ready after 1s, skipping")
                        break
                    }
                }

                if writerInput.isReadyForMoreMediaData {
                    adaptor.append(pb, withPresentationTime: presentationTime)
                }

                let done = Float(frameIndex + 1) / Float(totalFrames)
                DispatchQueue.main.async { progress(done) }

                if (frameIndex + 1) % Int(self.frameRate) == 0 {
                    print("[DEBUG] VideoExporter: " + String(frameIndex + 1)
                        + "/" + String(totalFrames) + " frames written")
                }
            }

            writerInput.markAsFinished()
            writer.finishWriting {
                DispatchQueue.main.async {
                    if writer.status == .completed {
                        print("[DEBUG] VideoExporter: export complete — " + url.lastPathComponent)
                        completion(nil)
                    } else {
                        let msg = writer.error?.localizedDescription ?? "unknown AVAssetWriter error"
                        print("[DEBUG] VideoExporter: export FAILED — " + msg)
                        completion(writer.error ?? ExportError.unknown)
                    }
                }
            }
        }
    }

    // MARK: - Metal texture creation

    private func makeColorTexture() -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage       = [.renderTarget]
        desc.storageMode = .private   // GPU-only render target
        let t = device.makeTexture(descriptor: desc)
        if t == nil { print("[DEBUG] VideoExporter: makeColorTexture returned nil") }
        return t
    }

    private func makeStagingTexture() -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead]
        // Apple Silicon uses unified memory (.shared); discrete GPU requires .managed + synchronize
        desc.storageMode = device.hasUnifiedMemory ? .shared : .managed
        let t = device.makeTexture(descriptor: desc)
        if t == nil { print("[DEBUG] VideoExporter: makeStagingTexture returned nil") }
        return t
    }

    /// Composites the raymarched fog volume over `dest` (which holds the scene),
    /// reading `depthTex` for occlusion.  Mirrors Renderer.drawFogVolume so the
    /// export matches the live preview exactly.
    private func drawFogVolume(commandBuffer: MTLCommandBuffer,
                               dest:          MTLTexture,
                               depthTex:      MTLTexture,
                               time:          Double) {
        guard let fog = fogSettings, fog.isEnabled,
              let pipe = fogVolumePipelineState else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture     = dest
        pass.colorAttachments[0].loadAction  = .load
        pass.colorAttachments[0].storeAction = .store
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var u = makeFogVolumeUniforms(fog,
            at:             time,
            playing:        true,   // export always reads the keyframe track
            viewProjection: camera.viewProjectionMatrix,
            cameraPos:      camera.eyePosition,
            colorMode:      colorMode.rawValue)
        enc.setRenderPipelineState(pipe)
        enc.setFragmentBytes(&u, length: MemoryLayout<FogVolumeUniforms>.stride, index: 0)
        enc.setFragmentTexture(depthTex, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    private func makeDepthTexture() -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        desc.usage       = [.renderTarget, .shaderRead]   // shaderRead: sampled by the fog pass
        desc.storageMode = .private
        let t = device.makeTexture(descriptor: desc)
        if t == nil { print("[DEBUG] VideoExporter: makeDepthTexture returned nil") }
        return t
    }

    // MARK: - Offscreen render

    private func renderFrame(colorTex:        MTLTexture,
                             stagingTex:       MTLTexture,
                             depthTex:         MTLTexture,
                             gradeTex:         MTLTexture?        = nil,
                             feedbackProc:     FeedbackProcessor? = nil,
                             feedbackSettings: FeedbackSettings?  = nil,
                             hitEffectTime:    Float              = 0,
                             sparkGPUData:     [SparkParticleGPU] = []) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            print("[DEBUG] VideoExporter: renderFrame — makeCommandBuffer nil")
            return
        }

        // When feedback is active, render the scene into the processor's intermediate
        // texture; it composites the result into colorTex after the scene pass.
        let feedbackActive = (feedbackSettings?.isEnabled == true)
                           && (feedbackProc?.sceneTexture != nil)
        let renderTarget = feedbackActive ? (feedbackProc!.sceneTexture ?? colorTex) : colorTex
        let renderDepth  = feedbackActive ? (feedbackProc!.depthTexture ?? depthTex)  : depthTex

        // ── Draw pass ─────────────────────────────────────────────────────────
        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture     = renderTarget
        passDesc.colorAttachments[0].loadAction  = .clear
        passDesc.colorAttachments[0].storeAction = .store
        // alpha=0 for background pixels when feedback is active (content mask).
        // When feedback is inactive renderTarget == colorTex so alpha is irrelevant.
        let bc = backgroundConfig.clearColor
        passDesc.colorAttachments[0].clearColor  = feedbackActive
            ? MTLClearColor(red: bc.red, green: bc.green, blue: bc.blue, alpha: 0.0)
            : bc
        passDesc.depthAttachment.texture          = renderDepth
        passDesc.depthAttachment.loadAction       = .clear
        passDesc.depthAttachment.storeAction      = .store   // preserved for excluded-laser post-pass
        passDesc.depthAttachment.clearDepth       = 1.0

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) {

            // ── Background gradient (drawn before scene geometry) ─────────────
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
            else if backgroundConfig.mode == .environment,
                    let skyPipe = skyboxPipelineState,
                    let bgDepth = backgroundDepthState,
                    let ibl     = ibl,
                    let cube    = ibl.envCubemap {
                encoder.setRenderPipelineState(skyPipe)
                encoder.setDepthStencilState(bgDepth)
                encoder.setCullMode(.none)
                let bgEquirect = backgroundEquirect ?? ibl.envEquirect
                var sky = SkyboxUniforms(
                    inverseViewProjection: simd_inverse(camera.viewProjectionMatrix),
                    cameraPos:             SIMD4<Float>(camera.eyePosition, 1),
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

            // ── Scene geometry ────────────────────────────────────────────────
            // Shared with the live Renderer via SceneGeometryEncoder so material,
            // flat-normal, and IBL handling stay identical between preview/export.
            // Holdout objects (hidden but occluding) are drawn depth-only first so
            // visible geometry behind them is cut to background — matches preview.
            let holdoutObjects = sceneManager.objects.filter { !$0.isVisible && $0.occludeWhenHidden }
            if !holdoutObjects.isEmpty, let holdout = holdoutPipelineState {
                SceneGeometryEncoder.encode(
                    into:            encoder,
                    objects:         holdoutObjects,
                    groupTransforms: sceneManager.groupTransforms,
                    lightUniforms:   lightManager.buildLightUniforms(),
                    context: SceneGeometryEncoder.Context(
                        viewProjection:    camera.viewProjectionMatrix,
                        eyePosition:       camera.eyePosition,
                        pipelineState:     holdout,
                        depthStencilState: depthStencilState,
                        colorMode:         colorMode,
                        isWireframe:       false,
                        exposure:          colorGradeSettings?.exposure ?? 1.0,
                        ibl:               ibl,
                        dummyUV:           dummyUVBuffer,
                        dummyTangent:      dummyTangentBuffer))
            }

            let visibleObjects = sceneManager.objects.filter { $0.isVisible }

            // Split into opaque + transparent, sort transparent back-to-front
            // from the camera so the over-compositing blend is correct.
            // Mirrors the live Renderer's split so preview/export match.
            let opaqueObjects:      [SceneObject]
            let transparentObjects: [SceneObject]
            if visibleObjects.contains(where: { $0.material.opacity < 1.0 }) {
                opaqueObjects = visibleObjects.filter { $0.material.opacity >= 1.0 }
                let eye = camera.eyePosition
                transparentObjects = visibleObjects
                    .filter { $0.material.opacity < 1.0 }
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
                    .sorted { $0.1 > $1.1 }
                    .map { $0.0 }
            } else {
                opaqueObjects      = visibleObjects
                transparentObjects = []
            }

            if !opaqueObjects.isEmpty {
                SceneGeometryEncoder.encode(
                    into:            encoder,
                    objects:         opaqueObjects,
                    groupTransforms: sceneManager.groupTransforms,
                    lightUniforms:   lightManager.buildLightUniforms(),
                    context: SceneGeometryEncoder.Context(
                        viewProjection:    camera.viewProjectionMatrix,
                        eyePosition:       camera.eyePosition,
                        pipelineState:     pipelineState,
                        depthStencilState: depthStencilState,
                        colorMode:         colorMode,
                        isWireframe:       isWireframe,
                        exposure:          colorGradeSettings?.exposure ?? 1.0,
                        ibl:               ibl,
                        dummyUV:           dummyUVBuffer,
                        dummyTangent:      dummyTangentBuffer))
            }

            if !transparentObjects.isEmpty,
               let tP  = transparentPipelineState,
               let tDS = transparentDepthState {
                SceneGeometryEncoder.encode(
                    into:            encoder,
                    objects:         transparentObjects,
                    groupTransforms: sceneManager.groupTransforms,
                    lightUniforms:   lightManager.buildLightUniforms(),
                    context: SceneGeometryEncoder.Context(
                        viewProjection:    camera.viewProjectionMatrix,
                        eyePosition:       camera.eyePosition,
                        pipelineState:     tP,
                        depthStencilState: tDS,
                        colorMode:         colorMode,
                        isWireframe:       isWireframe,
                        exposure:          colorGradeSettings?.exposure ?? 1.0,
                        ibl:               ibl,
                        dummyUV:           dummyUVBuffer,
                        dummyTangent:      dummyTangentBuffer))
            }

            // ── Weather particles (hitEffectTime carries the frame time t) ─────
            drawParticleEffects(encoder: encoder, time: Double(hitEffectTime))

            // ── Laser beam visuals + hit effects ──────────────────────────────
            let exportSize = SIMD2<Float>(Float(width), Float(height))
            drawLaserBeamsInEncoder(encoder,
                                    screenSize:   exportSize,
                                    excludedOnly: false)
            drawLaserHitsInEncoder(encoder, screenSize: exportSize,
                                   hitEffectTime: hitEffectTime, excludedOnly: false)
            if !feedbackActive {
                drawLaserBeamsInEncoder(encoder,
                                        screenSize:   exportSize,
                                        excludedOnly: true)
                drawLaserHitsInEncoder(encoder, screenSize: exportSize,
                                       hitEffectTime: hitEffectTime, excludedOnly: true)
                drawSparksInEncoder(encoder, sparkGPUData: sparkGPUData)
            }

            encoder.endEncoding()
        }

        // ── Feedback composite → colorTex ─────────────────────────────────────
        if feedbackActive, let fp = feedbackProc, let fs = feedbackSettings {
            fp.process(commandBuffer: commandBuffer, dest: colorTex, settings: fs)
        }

        // ── Excluded beams + hit effects + all sparks (after feedback, no trails) ──
        if feedbackActive, let fp = feedbackProc, let depthTex = fp.depthTexture {
            let exportSize = SIMD2<Float>(Float(width), Float(height))
            drawExcludedLaserBeams(commandBuffer: commandBuffer,
                                   dest:          colorTex,
                                   depthTex:      depthTex,
                                   screenSize:    exportSize,
                                   hitEffectTime: hitEffectTime,
                                   sparkGPUData:  sparkGPUData)
        }

        // ── Fog volume composite (feedback off only — matches the live preview) ──
        if !feedbackActive, fogSettings?.isEnabled == true {
            drawFogVolume(commandBuffer: commandBuffer, dest: colorTex, depthTex: depthTex,
                          time: Double(hitEffectTime))
        }

        // ── Axes gizmo overlay (bottom-right corner) ──────────────────────────
        if showAxesGizmo {
            drawGizmoPass(commandBuffer: commandBuffer, dest: colorTex)
        }

        // ── Color grade (brightness / contrast) ──────────────────────────────
        if let settings = colorGradeSettings, !settings.isIdentity,
           let gTex     = gradeTex,
           let pipeline = colorGradePipelineState {
            // Blit the rendered frame into the intermediate grade texture so the
            // fragment shader can sample it while writing back to colorTex.
            if let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.copy(from: colorTex, to: gTex)
                blit.endEncoding()
            }
            let gradePass = MTLRenderPassDescriptor()
            gradePass.colorAttachments[0].texture     = colorTex
            gradePass.colorAttachments[0].loadAction  = .dontCare
            gradePass.colorAttachments[0].storeAction = .store
            if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: gradePass) {
                enc.setRenderPipelineState(pipeline)
                enc.setFragmentTexture(gTex, index: 0)
                let gammaExp = 1.0 / max(settings.gamma, 0.01)
                var params = SIMD3<Float>(settings.brightness, settings.contrast, gammaExp)
                enc.setFragmentBytes(&params,
                                     length: MemoryLayout<SIMD3<Float>>.stride,
                                     index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                enc.endEncoding()
            }
        }

        // ── Blit color → staging; synchronize if needed for CPU readback ──────
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(from: colorTex, to: stagingTex)
            if !device.hasUnifiedMemory {
                blit.synchronize(resource: stagingTex)  // required for .managed on discrete GPU
            }
            blit.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()  // must finish before getBytes
    }

    // MARK: - Laser beam draw helpers (mirror Renderer's implementations)

    private func drawLaserBeamsInEncoder(_ encoder:    MTLRenderCommandEncoder,
                                          screenSize:   SIMD2<Float>,
                                          excludedOnly: Bool) {
        guard let pipeline = laserBeamPipelineState else { return }
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

    private func drawExcludedLaserBeams(commandBuffer: MTLCommandBuffer,
                                          dest:          MTLTexture,
                                          depthTex:      MTLTexture,
                                          screenSize:    SIMD2<Float>,
                                          hitEffectTime: Float,
                                          sparkGPUData:  [SparkParticleGPU]) {
        let hasBeams  = lightManager.lights.contains {
            $0.type == .laser && $0.isEnabled && $0.excludeBeamFromFeedback
        }
        let hasHits   = lightManager.lights.enumerated().contains {
            $0.element.type == .laser && $0.element.isEnabled
                && $0.element.excludeBeamFromFeedback
                && laserHitSystem.hits[$0.offset] != nil
        }
        let hasSparks = !sparkGPUData.isEmpty
        guard hasBeams || hasHits || hasSparks else { return }

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture     = dest
        passDesc.colorAttachments[0].loadAction  = .load
        passDesc.colorAttachments[0].storeAction = .store
        passDesc.depthAttachment.texture         = depthTex
        passDesc.depthAttachment.loadAction      = .load
        passDesc.depthAttachment.storeAction     = .dontCare

        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return }

        if hasBeams, let pipeline = laserBeamPipelineState {
            enc.setRenderPipelineState(pipeline)
            if let ds = laserBeamDepthState { enc.setDepthStencilState(ds) }
            enc.setCullMode(.none)
            let vp = camera.viewProjectionMatrix
            let indexedExcluded = lightManager.lights.enumerated().filter {
                $0.element.type == .laser && $0.element.isEnabled
                    && $0.element.excludeBeamFromFeedback
            }
            for (slotIndex, laser) in indexedExcluded {
                let start = laser.position
                let effectiveRange = laserHitSystem.hits[slotIndex].map {
                    min(laser.range, $0.distance)
                } ?? laser.range
                let end = start + simd_normalize(laser.direction) * effectiveRange
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

        drawLaserHitsInEncoder(enc, screenSize: screenSize,
                               hitEffectTime: hitEffectTime, excludedOnly: true)
        drawSparksInEncoder(enc, sparkGPUData: sparkGPUData)

        enc.endEncoding()
    }

    private func drawLaserHitsInEncoder(_ encoder:     MTLRenderCommandEncoder,
                                         screenSize:    SIMD2<Float>,
                                         hitEffectTime: Float,
                                         excludedOnly:  Bool) {
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

    private func drawSparksInEncoder(_ encoder:    MTLRenderCommandEncoder,
                                      sparkGPUData: [SparkParticleGPU]) {
        guard let pipeline = sparkPipelineState, !sparkGPUData.isEmpty else { return }

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

    /// Weather particles — mirrors Renderer.drawParticleEffects so export matches.
    private func drawParticleEffects(encoder: MTLRenderCommandEncoder, time: Double) {
        guard let mgr   = particleManager,
              let pipe  = particleFXPipelineState,
              let seeds = particleSeedBuffer,
              let ds    = laserBeamDepthState else { return }

        encoder.setRenderPipelineState(pipe)
        encoder.setDepthStencilState(ds)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(seeds, offset: 0, index: 0)

        for fx in mgr.emitters where fx.isEnabled {
            let density = fx.renderState(at: time, playing: true).density
            let count = Int((max(0, min(1, density)) * Float(ParticleEffect.maxCount)).rounded())
            guard count > 0 else { continue }

            var u = makeParticleFXUniforms(fx,
                viewProjection: camera.viewProjectionMatrix,
                cameraRight:    camera.rightVector,
                cameraUp:       camera.upVector,
                time:           Float(time),
                playing:        true,   // export always reads the keyframe track
                colorMode:      colorMode.rawValue)

            encoder.setVertexBytes(&u, length: MemoryLayout<ParticleFXUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&u, length: MemoryLayout<ParticleFXUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                   instanceCount: count)
        }
    }

    // MARK: - Axes gizmo (mirrors Renderer.drawGizmoPass exactly)

    /// Swift vertex struct — matches Metal `GizmoVertex` (float4 + float4 = 32 B).
    private struct GizmoVertex {
        var position: SIMD4<Float>
        var color:    SIMD4<Float>
    }

    private func drawGizmoPass(commandBuffer: MTLCommandBuffer,
                                dest: MTLTexture) {
        guard let pipeline = gizmoPipelineState else { return }

        let vm   = camera.viewMatrix
        let xDir = SIMD2<Float>(vm.columns.0.x, vm.columns.0.y)
        let yDir = SIMD2<Float>(vm.columns.1.x, vm.columns.1.y)
        let zDir = SIMD2<Float>(vm.columns.2.x, vm.columns.2.y)

        let fw: Float = Float(width); let fh: Float = Float(height)
        let gizmoRadius: Float = 36
        let margin:      Float = 18
        let cx    = 1.0 - (margin + gizmoRadius) / fw * 2
        let cy    = -1.0 + (margin + gizmoRadius) / fh * 2
        let scale = gizmoRadius * 2 / min(fw, fh)
        let thickness = 2.5 / fh

        let axisData: [(SIMD2<Float>, SIMD4<Float>)] = [
            (xDir, SIMD4<Float>(0.95, 0.25, 0.25, 1.0)),
            (yDir, SIMD4<Float>(0.25, 0.90, 0.25, 1.0)),
            (zDir, SIMD4<Float>(0.35, 0.55, 1.00, 1.0)),
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
            verts.append(GizmoVertex(position: SIMD4<Float>(cx - px, cy - py, 0, 1), color: col))
            verts.append(GizmoVertex(position: SIMD4<Float>(cx + px, cy + py, 0, 1), color: col))
            verts.append(GizmoVertex(position: SIMD4<Float>(ex - px, ey - py, 0, 1), color: col))
            verts.append(GizmoVertex(position: SIMD4<Float>(ex + px, ey + py, 0, 1), color: col))
        }

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture     = dest
        passDesc.colorAttachments[0].loadAction  = .load
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

    // MARK: - Pixel buffer readback

    private func pixelBufferFrom(_ texture: MTLTexture,
                                  pool: CVPixelBufferPool?,
                                  applyLumaAlpha: Bool) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?

        if let pool = pool {
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess else {
                print("[DEBUG] VideoExporter: CVPixelBufferPoolCreatePixelBuffer failed")
                return nil
            }
        } else {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey           as String: width,
                kCVPixelBufferHeightKey          as String: height
            ]
            guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                       attrs as CFDictionary, &pb) == kCVReturnSuccess else {
                print("[DEBUG] VideoExporter: CVPixelBufferCreate failed")
                return nil
            }
        }

        guard let buffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            print("[DEBUG] VideoExporter: CVPixelBufferGetBaseAddress returned nil")
            return nil
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        texture.getBytes(base,
                         bytesPerRow: bytesPerRow,
                         from: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                         size:   MTLSize(width: width, height: height, depth: 1)),
                         mipmapLevel: 0)

        // ── Alpha = Luma (Rec.709) — ProRes 4444 only ─────────────────────────
        // Pixel layout for kCVPixelFormatType_32BGRA: [B, G, R, A] per pixel.
        // Set A = 0.2126·R + 0.7152·G + 0.0722·B
        // Black background → A=0 (transparent); bright areas → A→255 (opaque).
        if applyLumaAlpha {
            let pixels = base.assumingMemoryBound(to: UInt8.self)
            for row in 0..<height {
                var offset = row * bytesPerRow
                for _ in 0..<width {
                    let b = Float(pixels[offset])
                    let g = Float(pixels[offset + 1])
                    let r = Float(pixels[offset + 2])
                    let luma: Float = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    pixels[offset + 3] = UInt8(min(255.0, luma + 0.5))
                    offset += 4
                }
            }
        }

        return buffer
    }

    // MARK: - Animation (independent of Timeline.currentTime)

    // Evaluates keyframes at the given time and writes directly to object transforms.
    // Does NOT modify timeline.currentTime — the live UI is unaffected during export.
    private func applyAnimation(at time: Double) {
        // ── Object transforms ─────────────────────────────────────────────────
        for object in sceneManager.objects {
            guard let track = object.keyframeTrack,
                  !track.keyframes.isEmpty else { continue }
            if let delta = track.evaluate(at: time) {
                if object.parentIndex != nil {
                    // Hierarchical part: baseTransform is a LOCAL transform; write
                    // localTransform and let applyHierarchy() below compute world transform.
                    object.localTransform = object.baseTransform * delta
                } else {
                    // Root / non-hierarchical: animate world transform directly.
                    object.transform = object.baseTransform * delta
                }
            }
        }

        // ── FK hierarchy propagation ──────────────────────────────────────────
        // Mirrors Renderer.applyHierarchy().  Must run after all per-object
        // localTransforms are written so parent world transforms are already current.
        let objects = sceneManager.objects
        for obj in objects {
            guard let parentIdx = obj.parentIndex,
                  parentIdx < objects.count else { continue }
            obj.transform = objects[parentIdx].transform * obj.localTransform
        }

        // ── Group-level transforms ────────────────────────────────────────────
        // Evaluate each group's keyframe track and store the result in
        // sceneManager.groupTransforms so renderFrame can apply it.
        for (gid, track) in sceneManager.groupKeyframeTracks {
            guard !track.keyframes.isEmpty else { continue }
            if let delta = track.evaluate(at: time) {
                sceneManager.groupTransforms[gid] = delta
            }
        }

        // ── Camera ────────────────────────────────────────────────────────────
        // Evaluated here so the gizmo and view/projection matrices track the
        // animation correctly.  CameraController is NOT ObservableObject, so
        // writing its properties from the export background queue is safe.
        if let camTrack = camera.keyframeTrack, !camTrack.keyframes.isEmpty {
            if let state = camTrack.evaluate(at: time) {
                camera.yaw         = state.yaw
                camera.pitch       = state.pitch
                camera.distance    = state.distance
                camera.target      = state.target
                camera.fovYRadians = state.fov
            }
            // Camera-follow override: replace target and yaw so the exported video
            // matches playback — camera tracks the object's position and orientation.
            // (Honor camera.followSuspended for symmetry with live rendering, even
            // though edit mode shouldn't be active during an export.)
            if !camera.followSuspended,
               let follow = camTrack.resolveFollowCamera(
                at:             time,
                getObjectState: { [self] name in sceneManager.worldOrbitAnchor(ofObjectNamed: name) }
            ) {
                camera.target = follow.target
                if let yaw   = follow.yaw   { camera.yaw   = yaw }
                if let pitch = follow.pitch {
                    camera.pitch = max(-Float.pi / 2 + 0.01,
                                    min( Float.pi / 2 - 0.01, pitch))
                }
            }
        }

        // ── Lights ────────────────────────────────────────────────────────────
        // During export the MTKView is paused and all rendering happens on the
        // dedicated export serial queue, so writing lightManager.lights here is
        // safe — there is no concurrent reader and Combine notifications fired
        // from this queue will be ignored (no UI is observing during export).
        for i in 0..<lightManager.lights.count {
            guard i < lightManager.keyframeTracks.count,
                  let track = lightManager.keyframeTracks[i],
                  !track.keyframes.isEmpty else { continue }
            if let state = track.evaluate(at: time) {
                lightManager.lights[i].intensity     = state.intensity
                lightManager.lights[i].color         = state.color
                lightManager.lights[i].position      = state.position
                lightManager.lights[i].target        = state.target
                lightManager.lights[i].range         = state.range
                lightManager.lights[i].beamThickness = state.beamThickness
            }
        }
    }

    // MARK: - Errors

    enum ExportError: LocalizedError {
        case zeroDuration
        case writerCreationFailed
        case cannotAddInput
        case textureCreationFailed
        case codecNotSupported
        case unknown

        var errorDescription: String? {
            switch self {
            case .zeroDuration:         return "Animation duration is zero — nothing to export"
            case .writerCreationFailed: return "Could not create AVAssetWriter for the output file"
            case .cannotAddInput:       return "Could not add video track to the output file"
            case .textureCreationFailed:return "Could not allocate Metal render textures"
            case .codecNotSupported:    return "ProRes 422 HQ codec not supported on this Mac"
            case .unknown:              return "An unknown export error occurred"
            }
        }
    }
}
