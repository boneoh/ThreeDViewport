import Foundation
import Metal
import AVFoundation
import CoreVideo
import CoreGraphics
import CoreText

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
    /// Color passes write alpha = Rec.709 luma of the RGB with full RGB, tagged
    /// Premultiplied so the RGB displays at correct brightness while the luma sits
    /// in alpha as a key — ready for DaVinci Resolve / LZX Videomancer without a
    /// separate key pass.  Matte passes keep the geometry coverage alpha (1 =
    /// geometry, 0 = background/holdout).
    case proRes4444

    /// ProRes 422 HQ — 10-bit 4:2:2, no alpha.
    /// Highest-quality 422 variant; standard professional codec for CG
    /// renders going into colour-grading pipelines.  Pure black background.
    case proRes422HQ

    var displayName: String {
        switch self {
        case .proRes4444:  return "ProRes 4444 — Premult alpha = Luma (compositing)"
        case .proRes422HQ: return "ProRes 422 HQ — solid black (grading)"
        }
    }

    var avCodecType: AVVideoCodecType {
        switch self {
        case .proRes4444:  return .proRes4444
        case .proRes422HQ: return .proRes422HQ
        }
    }

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
    // Non-published working copy of the lights, snapshotted at export start.
    // Per-frame animation writes here instead of the @Published lightManager.lights,
    // so the SwiftUI inspector doesn't churn and no main-thread hop is needed.
    private var exportLights:      [LightConfig] = []
    private let backgroundConfig:  BackgroundConfig
    private let pipelineState:     MTLRenderPipelineState
    private let depthStencilState: MTLDepthStencilState
    // Shared compositing core (built by the Renderer).  Owns the effect pipelines
    // and the pass encoders (e.g. encodeBackground) so export matches preview.
    private let scenePipeline:     ScenePipeline
    // Holdout (depth-only) pipeline — shared from the Renderer so exports occlude
    // identically to the preview.  nil disables the holdout pass.
    private let holdoutPipelineState: MTLRenderPipelineState?
    // Transparent (alpha-blended, no depth write) pipeline + matching depth state.
    // Shared from the Renderer.  nil = transparent pass skipped (export will draw
    // opacity<1 parts opaquely, matching pre-feature behaviour).
    private let transparentPipelineState: MTLRenderPipelineState?
    private let transparentDepthState:    MTLDepthStencilState?
    // Holdout re-stamp depth state (.lessEqual, no write) — shared from the Renderer.
    // Re-paints the black holdout silhouettes over background glass so held-out holes
    // stay pure black for the keyer while real background glass still renders.
    private let holdoutRestampDepthState: MTLDepthStencilState?
    // Depth-only pipeline (no colour writes) — shared from the Renderer.  Stamps
    // transparent feedback-ON geometry's depth so feedback-OFF opaque geometry drawn
    // after the composite is occluded by transparent objects in front of it.
    private let depthOnlyPipelineState: MTLRenderPipelineState?
    private let animStart:         Double   // first animation time (seconds); 0 = full timeline
    private let animDuration:      Double   // length of the exported range (seconds)
    private let timelineDuration:  Double   // full timeline length — cutoff for past-end keyframes
    private let frameRate:         Double
    private let frameTimescale:    Int32   // CMTime timescale (rational, exact for NTSC)
    private let frameTicks:        Int32   // CMTime value advanced per frame

    // Active codec for the current export — set at the top of export(). Used by
    // pixelBufferFrom to decide alpha handling (luma alpha for 4444 color passes).
    private var activeCodec: ExportCodec = .proRes4444

    // Seconds of 3-2-1 sync countdown prepended to every export (a white flash
    // frame is appended after, as the frame-accurate alignment point).
    private let countdownSeconds = 3

    // Phase 8+: rendering options matching the live display
    var colorMode:     RenderColorMode = .color
    var isWireframe:   Bool = false
    var showAxesGizmo: Bool = false

    // Phase 1c: scheduled camera cuts.  When non-empty, each frame renders the program
    // camera the schedule selects (instead of the single live camera).  Set by startExport.
    var cameras:           [SceneCamera] = []
    var cameraCuts:        [CameraCut]   = []
    var activeCameraIndex: Int           = 0

    /// Program camera index at time `t` (mirrors ViewportView.programCameraIndex).
    private func programCameraIndex(at t: Double) -> Int {
        guard !cameraCuts.isEmpty else { return activeCameraIndex }
        let sorted = cameraCuts.sorted { $0.time < $1.time }
        var idx = sorted[0].cameraIndex
        for c in sorted where c.time <= t + 1e-9 { idx = c.cameraIndex }
        return min(max(0, idx), cameras.count - 1)
    }

    // Probe marks rendered into the export when `marksVisible` is on (mirrors the
    // live viewport's drawMarks).  Set by ViewportView.startExport.
    var marks:        [ProbeMark] = []
    var marksVisible: Bool        = false
    private var widgetPipelineState: MTLRenderPipelineState?

    // 1×1 placeholder for the skybox equirect slot when the IBL has no equirect
    // source.  The effect pipelines themselves live in the shared ScenePipeline;
    // this texture is passed into it via the per-frame SceneRenderContext.
    private var dummyEquirect:           MTLTexture?
    /// Dedicated background HDR equirect, shared from the Renderer so export matches.
    var backgroundEquirect:              MTLTexture?

    // Feedback settings — nil means no feedback during export
    var feedbackSettings: FeedbackSettings?

    // Color grade settings — nil or identity = no grade pass during export
    var colorGradeSettings: ColorGradeSettings?

    // Fog settings — nil = no fog during export
    var fogSettings: FogSettings?
    // (Fog volume pipeline now lives in ScenePipeline.)

    // Weather particles — nil/empty = none during export
    var particleManager: ParticleManager?
    // (Particle pipeline + seed buffer now live in ScenePipeline.)

    // When false, laser beams / hits / sparks are skipped.  Export All's Solo/Matte
    // passes set this so the actor/macguffin matte has no laser FX (fog + weather
    // particles are gated separately by nil-ing fogSettings/particleManager).
    var includeLaserFX: Bool = true

    // Phase C: image-based lighting — shared with the live Renderer so exports
    // match the viewport.  Set by ViewportView after construction.
    var ibl: IBL?

    // Fallback buffers for objects without UVs / tangents
    private var dummyUVBuffer:      MTLBuffer?
    private var dummyTangentBuffer: MTLBuffer?

    // Gizmo pipeline — built lazily from the same Metal library as the scene pipeline
    private var gizmoPipelineState: MTLRenderPipelineState?

    // Laser beam/hit/spark + color grade pipelines now live in ScenePipeline.  The
    // read-only laser depth state stays here as a handle because the export's
    // probe-marks overlay reuses it (matching the live renderer).
    private var laserBeamDepthState:    MTLDepthStencilState?

    // Luma-alpha pipeline (fullscreen; rewrites alpha = Rec.709 luma for 4444 color)
    private var lumaAlphaPipelineState: MTLRenderPipelineState?

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
          rangeStart:        Double = 0,
          rangeEnd:          Double? = nil,
          pipelineState:     MTLRenderPipelineState,
          depthStencilState: MTLDepthStencilState,
          scenePipeline:     ScenePipeline,
          holdoutPipelineState: MTLRenderPipelineState? = nil,
          transparentPipelineState: MTLRenderPipelineState? = nil,
          transparentDepthState:    MTLDepthStencilState?   = nil,
          holdoutRestampDepthState: MTLDepthStencilState?   = nil,
          depthOnlyPipelineState:   MTLRenderPipelineState? = nil) {

        self.device            = device
        self.commandQueue      = commandQueue
        self.sceneManager      = sceneManager
        self.camera            = camera
        self.lightManager      = lightManager
        self.backgroundConfig  = backgroundConfig
        self.pipelineState     = pipelineState
        self.depthStencilState = depthStencilState
        self.scenePipeline     = scenePipeline
        self.holdoutPipelineState     = holdoutPipelineState
        self.transparentPipelineState = transparentPipelineState
        self.transparentDepthState    = transparentDepthState
        self.holdoutRestampDepthState = holdoutRestampDepthState
        self.depthOnlyPipelineState   = depthOnlyPipelineState
        // Export range: clamp to [0, duration]; an empty/inverted range falls back
        // to the full timeline so a bad In/Out can't produce a zero-length export.
        let clampStart = max(0, min(rangeStart, timeline.duration))
        let clampEnd   = max(clampStart, min(rangeEnd ?? timeline.duration, timeline.duration))
        let len        = clampEnd - clampStart
        self.animStart         = len > 0 ? clampStart : 0
        self.animDuration      = len > 0 ? len : timeline.duration
        self.timelineDuration  = timeline.duration
        self.frameRate         = fps.value
        self.frameTimescale    = fps.timescale
        self.frameTicks        = fps.frameDuration

        // Effect pipeline states + per-pass encoders come from the shared
        // ScenePipeline so export matches preview by construction.  The only state
        // read directly here is the read-only laser depth state, reused by the
        // probe-marks overlay.
        self.laserBeamDepthState     = scenePipeline.laserBeamDepthState

        // Dummy buffers for objects without UV / tangent data
        var dummyUV:  [Float] = [0, 0]
        var dummyTan: [Float] = [1, 0, 0, 1]
        dummyUVBuffer = device.makeBuffer(bytes: &dummyUV,
                                          length: 2 * MemoryLayout<Float>.stride,
                                          options: .storageModeShared)
        dummyTangentBuffer = device.makeBuffer(bytes: &dummyTan,
                                               length: 4 * MemoryLayout<Float>.stride,
                                               options: .storageModeShared)

        // The skybox draw (in ScenePipeline) still needs a 1×1 placeholder for its
        // equirect slot when the IBL has no equirect source; it's passed via the
        // per-frame context.
        let dDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
        dDesc.usage = [.shaderRead]
        dummyEquirect = device.makeTexture(descriptor: dDesc)

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

        // Widget (world-space line) pipeline — same shaders as the live renderer,
        // used to draw probe marks into the export.
        if let library    = try? device.makeDefaultLibrary(bundle: Bundle.module),
           let widgetV    = library.makeFunction(name: "widget_vertex"),
           let widgetF    = library.makeFunction(name: "widget_fragment") {
            let widgetDesc = MTLRenderPipelineDescriptor()
            widgetDesc.label                           = "WidgetExport"
            widgetDesc.vertexFunction                  = widgetV
            widgetDesc.fragmentFunction                = widgetF
            widgetDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
            widgetDesc.depthAttachmentPixelFormat      = .depth32Float
            widgetPipelineState = try? device.makeRenderPipelineState(descriptor: widgetDesc)
            print("[DEBUG] VideoExporter: widget pipeline "
                + (widgetPipelineState != nil ? "created" : "FAILED"))
        }

        // Laser beam/hit, spark, weather particle (+ its seed buffer), fog volume,
        // and color grade pipelines now come from the shared ScenePipeline.

        // Luma-alpha pipeline (fullscreen alpha-rewrite) is export-only, so it
        // stays here.  It reuses the color-grade fullscreen-quad vertex function.
        if let library     = try? device.makeDefaultLibrary(bundle: Bundle.module),
           let gradeVertFn = library.makeFunction(name: "color_grade_vertex"),
           let lumaFragFn  = library.makeFunction(name: "luma_alpha_fragment") {
            let lumaDesc = MTLRenderPipelineDescriptor()
            lumaDesc.label                           = "LumaAlphaExport"
            lumaDesc.vertexFunction                  = gradeVertFn
            lumaDesc.fragmentFunction                = lumaFragFn
            lumaDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
            lumaAlphaPipelineState = try? device.makeRenderPipelineState(descriptor: lumaDesc)
            print("[DEBUG] VideoExporter: luma-alpha pipeline "
                + (lumaAlphaPipelineState != nil ? "created" : "FAILED"))
        }

        print("[DEBUG] VideoExporter: initialized — duration="
            + String(format: "%.1f", timeline.duration)
            + "s frameRate=" + String(format: "%.0f", timeline.frameRate)
            + " totalFrames=" + String(Int(timeline.duration * timeline.frameRate)))
    }

    // MARK: - Public export entry point

    /// Exports the full animation to a ProRes .mov at the given URL.
    /// `codec` selects ProRes 4444 (Premult alpha=Luma on color passes) or ProRes 422 HQ (solid black).
    /// `progress` is called on the main thread with values 0.0–1.0.
    /// `completion` is called on the main thread; nil = success, otherwise Error.
    func export(to url: URL,
                codec:      ExportCodec,
                progress:   @escaping (Float)   -> Void,
                completion: @escaping (Error?)  -> Void) {

        activeCodec = codec

        let animFrames = Int(animDuration * frameRate)
        guard animFrames > 0 else {
            print("[DEBUG] VideoExporter: export — animFrames is zero, aborting")
            DispatchQueue.main.async { completion(ExportError.zeroDuration) }
            return
        }

        // Prepended sync countdown: 3 seconds of 3-2-1 on black + one white flash
        // frame (the frame-accurate alignment point), then the animation.  Content
        // timing is unchanged — only the writer's presentation times are offset.
        let fpsInt         = max(1, Int(frameRate.rounded()))
        let countdownTotal = countdownSeconds * fpsInt + 1   // +1 = flash frame
        let totalFrames    = countdownTotal + animFrames     // full file length

        print("[DEBUG] VideoExporter: export start — "
            + String(animFrames) + " anim + " + String(countdownTotal)
            + " countdown frames → " + url.lastPathComponent)

        // ── Offscreen render-target pool ──────────────────────────────────────
        // Two slots lets the GPU render frame N while the CPU reads back and
        // encodes frame N-1 (pipelined).  Feedback forces a single slot: its
        // queue reuses shared textures across frames and must stay strictly
        // serial.  gradeTex is the per-slot blit intermediate, shared by the Color
        // Grade and luma-alpha fullscreen passes (both blit colorTex→grade→colorTex).
        let pipelineDepth = (feedbackSettings?.isEnabled == true) ? 1 : 2
        let needGrade     = (colorGradeSettings.map { !$0.isIdentity } ?? false)
        let needLumaAlpha = (codec == .proRes4444 && colorMode == .color)
        let needIntermediate = needGrade || needLumaAlpha
        var slots: [(color: MTLTexture, staging: MTLTexture,
                     depth: MTLTexture, grade: MTLTexture?)] = []
        for _ in 0..<pipelineDepth {
            guard let c = makeColorTexture(),
                  let s = makeStagingTexture(),
                  let d = makeDepthTexture() else {
                DispatchQueue.main.async { completion(ExportError.textureCreationFailed) }
                return
            }
            let g = needIntermediate ? makeGradeTexture() : nil
            if needIntermediate && g == nil {
                DispatchQueue.main.async { completion(ExportError.textureCreationFailed) }
                return
            }
            slots.append((color: c, staging: s, depth: d, grade: g))
        }

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

            // Snapshot the lights once; animation evaluates into this copy so the
            // published lightManager.lights (and the UI bound to it) stays put.
            self.exportLights = self.lightManager.lights

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

            // ── Prepend sync countdown ────────────────────────────────────────
            // Generate the 4 distinct frames once (3, 2, 1, flash) and append each
            // at its writer presentation time.  These go through the same adaptor,
            // so resolution / fps / codec / color + alpha tags match the rest of
            // the file automatically.  Identical across every Export All pass.
            let countdownDigits = (0..<self.countdownSeconds).map { sec in
                self.makeCountdownPixelBuffer(kind: .number(self.countdownSeconds - sec))
            }
            let flashBuffer = self.makeCountdownPixelBuffer(kind: .flash)
            for i in 0..<countdownTotal {
                let buffer: CVPixelBuffer?
                if i < self.countdownSeconds * fpsInt {
                    buffer = countdownDigits[i / fpsInt]   // F frames per digit
                } else {
                    buffer = flashBuffer                   // final flash frame
                }
                guard let pb = buffer else { continue }
                let pts = CMTime(value: CMTimeValue(i) * CMTimeValue(self.frameTicks),
                                 timescale: self.frameTimescale)
                self.appendPixelBuffer(pb, at: pts, adaptor: adaptor, writerInput: writerInput)
            }

            // In-flight frames: each holds the committed GPU buffer plus the slot
            // staging texture to read back once it finishes.  Drained FIFO so frames
            // are appended in order (single queue ⇒ buffers complete in commit order).
            var pending: [(cb: MTLCommandBuffer, staging: MTLTexture,
                           frameIndex: Int, pts: CMTime)] = []

            func drainOldest() {
                let p = pending.removeFirst()
                p.cb.waitUntilCompleted()   // usually already done — GPU ran while we worked
                self.appendFrame(staging:          p.staging,
                                 frameIndex:       p.frameIndex,
                                 presentationTime: p.pts,
                                 adaptor:          adaptor,
                                 writerInput:      writerInput,
                                 totalFrames:      totalFrames,
                                 progress:         progress)
            }

            for frameIndex in 0..<animFrames {
                // Writer index is offset past the prepended countdown; content time
                // (t) is not — the animation still starts from t=0.
                let writerIndex = countdownTotal + frameIndex
                // Rational timing — exact for NTSC rates (e.g. 30000/1001).
                let presentationTime = CMTime(value: CMTimeValue(writerIndex) * CMTimeValue(self.frameTicks),
                                              timescale: self.frameTimescale)
                let t = self.animStart + Double(frameIndex) * Double(self.frameTicks) / Double(self.frameTimescale)

                // Free the slot we're about to reuse (drains the GPU/readback of an
                // earlier frame).  At depth 2 this is frame N-2, leaving N-1 in flight.
                while pending.count >= pipelineDepth { drainOldest() }

                // Evaluate animation at this exact time — does NOT touch Timeline.currentTime.
                // Runs on the export queue (no main-thread hop): the MTKView is paused
                // so there's no concurrent reader, and the only @Published target (lights)
                // is now written to the non-published exportLights copy instead.
                self.applyAnimation(at: t)

                // Laser hit detection + particle simulation (deterministic, uses frame time)
                let frameDt     = Float(1.0 / self.frameRate)
                let frameHitTime = Float(t)
                // Pass all objects; nearestHit decides what occludes (visible OR
                // opaque holdout), so held-out geometry stops the laser in FX passes.
                self.laserHitSystem.updateHits(lights: self.exportLights,
                                               objects: self.sceneManager.objects,
                                               groupTransforms: self.sceneManager.groupTransforms)
                self.laserHitSystem.updateParticles(dt: frameDt)
                let sparkGPUData = self.laserHitSystem.buildSparkGPUData()

                // Render into this frame's slot and commit (no wait — pipelined).
                let slot = slots[frameIndex % pipelineDepth]
                guard let cb = self.renderFrame(colorTex:        slot.color,
                                                stagingTex:       slot.staging,
                                                depthTex:         slot.depth,
                                                gradeTex:         slot.grade,
                                                feedbackProc:     exportFeedback,
                                                feedbackSettings: self.feedbackSettings,
                                                hitEffectTime:    frameHitTime,
                                                sparkGPUData:     sparkGPUData) else {
                    print("[DEBUG] VideoExporter: frame " + String(frameIndex)
                        + " — renderFrame failed, skipping")
                    continue
                }
                pending.append((cb: cb, staging: slot.staging,
                                frameIndex: writerIndex, pts: presentationTime))
            }

            // Drain the frames still in flight, in order.
            while !pending.isEmpty { drainOldest() }

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

    // (Fog volume composite now lives in ScenePipeline.encodeFogVolume.)

    private func makeDepthTexture() -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        desc.usage       = [.renderTarget, .shaderRead]   // shaderRead: sampled by the fog pass
        desc.storageMode = .private
        let t = device.makeTexture(descriptor: desc)
        if t == nil { print("[DEBUG] VideoExporter: makeDepthTexture returned nil") }
        return t
    }

    private func makeGradeTexture() -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage       = [.shaderRead, .renderTarget]
        desc.storageMode = .private
        let t = device.makeTexture(descriptor: desc)
        if t == nil { print("[DEBUG] VideoExporter: makeGradeTexture returned nil") }
        return t
    }

    // MARK: - Geometry encode helpers (mirror the live Renderer's split)

    /// Splits a visible-object list into (opaque, transparent), transparent sorted
    /// back-to-front.
    private func splitOpaqueTransparent(_ objects: [SceneObject])
        -> (opaque: [SceneObject], transparent: [SceneObject]) {
        func isTransparent(_ o: SceneObject) -> Bool {
            o.material.opacity < 1.0 || o.material.baseColorFactor.w < 1.0
        }
        guard objects.contains(where: isTransparent) else { return (objects, []) }
        let opaque = objects.filter { !isTransparent($0) }
        let eye = camera.eyePosition
        let transparent = objects.filter(isTransparent)
            .map { obj -> (SceneObject, Float) in
                let m: matrix_float4x4
                if let gid = obj.groupID, let gt = sceneManager.groupTransforms[gid] {
                    m = gt * obj.transform
                } else { m = obj.transform }
                let p = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
                let d = p - eye
                return (obj, dot(d, d))
            }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
        return (opaque, transparent)
    }

    /// Encodes the holdout silhouettes (depth-only black matte) with the given depth
    /// state.  Used twice per frame: first with the normal write-on depth state to cut
    /// geometry behind them, then (after glass) with the .lessEqual write-off state to
    /// re-paint pure black over any background glass that overlapped them.
    private func encodeHoldouts(_ objects: [SceneObject],
                                depthState: MTLDepthStencilState,
                                into encoder: MTLRenderCommandEncoder) {
        guard !objects.isEmpty, let holdout = holdoutPipelineState else { return }
        SceneGeometryEncoder.encode(
            into:            encoder,
            objects:         objects,
            groupTransforms: sceneManager.groupTransforms,
            lightUniforms:   lightManager.buildLightUniforms(from: exportLights),
            context: SceneGeometryEncoder.Context(
                viewProjection:    camera.viewProjectionMatrix,
                eyePosition:       camera.eyePosition,
                pipelineState:     holdout,
                depthStencilState: depthState,
                colorMode:         colorMode,
                isWireframe:       false,
                exposure:          colorGradeSettings?.exposure ?? 1.0,
                ibl:               ibl,
                dummyUV:           dummyUVBuffer,
                dummyTangent:      dummyTangentBuffer,
                dummy2D:           dummyEquirect))
    }

    /// Stamps `objects`' depth into the current depth attachment without writing colour
    /// (depth-write on, colour masked off).  Feedback path: transparent feedback-ON
    /// geometry renders depth-write OFF, so without this the feedback-OFF opaque
    /// geometry drawn after the composite isn't occluded by it.
    private func encodeDepthOnly(_ objects: [SceneObject], into encoder: MTLRenderCommandEncoder) {
        guard !objects.isEmpty, let dP = depthOnlyPipelineState else { return }
        SceneGeometryEncoder.encode(
            into:            encoder,
            objects:         objects,
            groupTransforms: sceneManager.groupTransforms,
            lightUniforms:   lightManager.buildLightUniforms(from: exportLights),
            context: SceneGeometryEncoder.Context(
                viewProjection:    camera.viewProjectionMatrix,
                eyePosition:       camera.eyePosition,
                pipelineState:     dP,
                depthStencilState: depthStencilState,   // .less, depth-write ON
                colorMode:         colorMode,
                isWireframe:       false,
                exposure:          colorGradeSettings?.exposure ?? 1.0,
                ibl:               ibl,
                dummyUV:           dummyUVBuffer,
                dummyTangent:      dummyTangentBuffer,
                dummy2D:           dummyEquirect))
    }

    private func encodeOpaqueGeometry(_ objects: [SceneObject], into encoder: MTLRenderCommandEncoder) {
        guard !objects.isEmpty else { return }
        SceneGeometryEncoder.encode(
            into:            encoder,
            objects:         objects,
            groupTransforms: sceneManager.groupTransforms,
            lightUniforms:   lightManager.buildLightUniforms(from: exportLights),
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
                dummyTangent:      dummyTangentBuffer,
                dummy2D:           dummyEquirect))
    }

    private func encodeTransparentGeometry(_ objects: [SceneObject], into encoder: MTLRenderCommandEncoder) {
        guard !objects.isEmpty,
              let tP = transparentPipelineState, let tDS = transparentDepthState else { return }
        let context = SceneGeometryEncoder.Context(
            viewProjection:    camera.viewProjectionMatrix,
            eyePosition:       camera.eyePosition,
            pipelineState:     tP,
            depthStencilState: tDS,
            colorMode:         colorMode,
            isWireframe:       isWireframe,
            exposure:          colorGradeSettings?.exposure ?? 1.0,
            ibl:               ibl,
            dummyUV:           dummyUVBuffer,
            dummyTangent:      dummyTangentBuffer,
            dummy2D:           dummyEquirect)
        let lightUniforms = lightManager.buildLightUniforms(from: exportLights)

        // Two passes: back faces first (cull front), then front faces (cull back) —
        // mirrors the Renderer so a closed/convex glass mesh composites correctly from
        // any angle without a per-triangle depth sort (depth-write is off).
        for cull in [MTLCullMode.front, MTLCullMode.back] {
            encoder.setCullMode(cull)
            SceneGeometryEncoder.encode(
                into:            encoder,
                objects:         objects,
                groupTransforms: sceneManager.groupTransforms,
                lightUniforms:   lightUniforms,
                context:         context)
        }
        // Restore the default no-cull state for any later draws in this encoder.
        encoder.setCullMode(.none)
    }

    // MARK: - Offscreen render

    private func renderFrame(colorTex:        MTLTexture,
                             stagingTex:       MTLTexture,
                             depthTex:         MTLTexture,
                             gradeTex:         MTLTexture?        = nil,
                             feedbackProc:     FeedbackProcessor? = nil,
                             feedbackSettings: FeedbackSettings?  = nil,
                             hitEffectTime:    Float              = 0,
                             sparkGPUData:     [SparkParticleGPU] = []) -> MTLCommandBuffer? {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            print("[DEBUG] VideoExporter: renderFrame — makeCommandBuffer nil")
            return nil
        }

        // When feedback is active, render the scene into the processor's intermediate
        // texture; it composites the result into colorTex after the scene pass.
        let feedbackActive = (feedbackSettings?.isEnabled == true)
                           && (feedbackProc?.sceneTexture != nil)
        let renderTarget = feedbackActive ? (feedbackProc!.sceneTexture ?? colorTex) : colorTex
        let renderDepth  = feedbackActive ? (feedbackProc!.depthTexture ?? depthTex)  : depthTex
        // Environment excluded from feedback: foreground-only into the feedback
        // texture, skybox drawn fresh onto colorTex, composite over it (matches live).
        let excludeBg = feedbackActive
                     && backgroundConfig.mode == .environment
                     && backgroundConfig.excludeEnvironmentFromFeedback

        // Per-frame context shared by every ScenePipeline pass this frame.  Export
        // always reads the keyframe track (playing = true); fog time matches the
        // existing behaviour (Double(hitEffectTime)).
        let sceneCtx = SceneRenderContext(
            viewProjection:     camera.viewProjectionMatrix,
            eyePosition:        camera.eyePosition,
            cameraRight:        camera.rightVector,
            cameraUp:           camera.upVector,
            background:         backgroundConfig,
            backgroundEquirect: backgroundEquirect,
            ibl:                ibl,
            colorMode:          colorMode,
            dummyEquirect:      dummyEquirect,
            time:               Double(hitEffectTime),
            playing:            true,
            fog:                fogSettings,
            particles:          particleManager,
            lights:             exportLights,
            lasers:             laserHitSystem,
            screenSize:         SIMD2<Float>(Float(width), Float(height)),
            hitEffectTime:      hitEffectTime,
            sparkGPUData:       sparkGPUData)

        // ── Draw pass ─────────────────────────────────────────────────────────
        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture     = renderTarget
        passDesc.colorAttachments[0].loadAction  = .clear
        passDesc.colorAttachments[0].storeAction = .store
        // Clear alpha = 0 so background pixels read as a transparent coverage matte
        // in the ProRes 4444 alpha channel (geometry fragments write alpha = 1,
        // background/skybox shaders and holdout write 0).  Also the content mask
        // the feedback compositor uses.  RGB clear stays the background colour.
        let bc = backgroundConfig.clearColor
        passDesc.colorAttachments[0].clearColor  = excludeBg
            ? MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0.0)   // foreground-only
            : MTLClearColor(red: bc.red, green: bc.green, blue: bc.blue, alpha: 0.0)
        passDesc.depthAttachment.texture          = renderDepth
        passDesc.depthAttachment.loadAction       = .clear
        passDesc.depthAttachment.storeAction      = .store   // preserved for excluded-laser post-pass
        passDesc.depthAttachment.clearDepth       = 1.0

        // Per-object feedback opt-out (see Renderer): feedback-on objects draw now
        // (trail); feedback-off objects draw after the composite (no trails).
        // Hoisted above the encoder block so the off-lane is in scope for that pass.
        let visibleObjects = sceneManager.objects.filter { $0.isVisible }
        let visibleOn:  [SceneObject]
        let visibleOff: [SceneObject]
        if feedbackActive {
            visibleOn  = visibleObjects.filter { $0.feedbackEnabled }
            visibleOff = visibleObjects.filter { !$0.feedbackEnabled }
        } else {
            visibleOn  = visibleObjects
            visibleOff = []
        }

        // Holdout objects (hidden but occluding); hoisted so the opaque-only FX depth
        // pre-pass below can reuse them.  Transparent parts are excluded — they don't
        // block weather/fog/lasers.
        let holdoutObjects = sceneManager.objects.filter {
            !$0.isVisible && $0.occludeWhenHidden
                && !($0.material.opacity < 1.0 || $0.material.baseColorFactor.w < 1.0)
        }

        // Opaque-only depth for fog + excluded lasers, so transparent glass doesn't
        // clip those FX behind windows (mirrors the live Renderer).  Allocated per
        // frame — export is offline, so the extra textures are cheap.
        let hasExcludedBeams = exportLights.contains {
            $0.type == .laser && $0.isEnabled && $0.excludeBeamFromFeedback
        }
        let needFxDepth = (fogSettings?.isEnabled == true)
                       || (feedbackActive && includeLaserFX && hasExcludedBeams)
        let fxDepth: MTLTexture? = needFxDepth ? makeDepthTexture() : nil
        let fxColor: MTLTexture? = needFxDepth ? makeGradeTexture() : nil

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) {

            // ── Background gradient / environment skybox ──────────────────────
            // Skybox skipped here when excluding from feedback — drawn fresh onto
            // colorTex after the scene pass so the foreground composites over it.
            if !excludeBg {
                scenePipeline.encodeBackground(into: encoder, sceneCtx)
            }

            // ── Scene geometry ────────────────────────────────────────────────
            // Shared with the live Renderer via SceneGeometryEncoder so material,
            // flat-normal, and IBL handling stay identical between preview/export.
            // Holdout objects (hidden but occluding) are drawn depth-only first so
            // visible geometry behind them is cut to background — matches preview.
            // Transparent parts (glass) are excluded: they don't block weather/fog
            // when visible, so they must not occlude FX as depth-only holdouts.
            // (holdoutObjects hoisted above for reuse by the FX depth pre-pass.)
            encodeHoldouts(holdoutObjects, depthState: depthStencilState, into: encoder)

            // Feedback-on lane, split opaque/transparent (opacity + baseColorFactor.w
            // handled in splitOpaqueTransparent).
            let (onOpaque, onTransparent) = splitOpaqueTransparent(visibleOn)

            encodeOpaqueGeometry(onOpaque, into: encoder)

            // ── Weather particles (hitEffectTime carries the frame time t) ─────
            // Drawn AFTER opaque but BEFORE transparent geometry so the smoke is
            // occluded by opaque surfaces yet stays visible through translucent
            // ones (glass windows) — mirrors the live Renderer ordering.
            scenePipeline.encodeParticles(into: encoder, sceneCtx)

            // ── Laser beam visuals + hit effects ──────────────────────────────
            // Drawn BEFORE transparent geometry (same reason as the particles):
            // glass windows write depth, so a read-only beam fragment behind the
            // glass would be depth-rejected.  Mirrors the live Renderer ordering.
            if includeLaserFX {
                scenePipeline.encodeLaserBeams(into: encoder, excludedOnly: false, sceneCtx)
                scenePipeline.encodeLaserHits(into:  encoder, excludedOnly: false, sceneCtx)
                if !feedbackActive {
                    scenePipeline.encodeLaserBeams(into: encoder, excludedOnly: true, sceneCtx)
                    scenePipeline.encodeLaserHits(into:  encoder, excludedOnly: true, sceneCtx)
                    scenePipeline.encodeSparks(into: encoder, sceneCtx)
                }
            }

            encodeTransparentGeometry(onTransparent, into: encoder)

            // Feedback lane split: stamp transparent feedback-ON geometry's depth (it
            // rendered depth-write off) so the feedback-OFF opaque geometry drawn after
            // the composite is occluded by transparent objects in front of it.
            if feedbackActive, !visibleOff.isEmpty {
                encodeDepthOnly(onTransparent, into: encoder)
            }

            // Re-stamp the holdout silhouettes over the glass so held-out holes stay
            // pure black for the keyer (.lessEqual matches the silhouette depth the
            // depth-write-off glass left intact; fails where opaque foreground is
            // nearer).  Background glass NOT over a holdout is untouched.
            if let rDS = holdoutRestampDepthState {
                encodeHoldouts(holdoutObjects, depthState: rDS, into: encoder)
            }

            drawMarksInEncoder(encoder, viewProjection: camera.viewProjectionMatrix)

            encoder.endEncoding()
        }

        // ── Opaque-only depth pre-pass (fog + excluded lasers) ────────────────
        // Opaque geometry + opaque holdouts depth-only into fxDepth, so the fog
        // raymarch / excluded-laser pass clamp against opaque depth (not glass).
        if needFxDepth, let fx = fxDepth, let fxc = fxColor {
            let desc = MTLRenderPassDescriptor()
            desc.colorAttachments[0].texture     = fxc
            desc.colorAttachments[0].loadAction  = .clear
            desc.colorAttachments[0].storeAction = .dontCare
            desc.depthAttachment.texture         = fx
            desc.depthAttachment.loadAction      = .clear
            desc.depthAttachment.clearDepth      = 1.0
            desc.depthAttachment.storeAction     = .store
            if let fxEnc = commandBuffer.makeRenderCommandEncoder(descriptor: desc) {
                let (opaque, _) = splitOpaqueTransparent(visibleObjects)
                encodeOpaqueGeometry(opaque + holdoutObjects, into: fxEnc)
                fxEnc.endEncoding()
            }
        }

        // Environment-excluded-from-feedback: draw the skybox fresh onto colorTex
        // first, so the feedback composite lands over it (matches the live preview).
        if excludeBg {
            let bgPass = MTLRenderPassDescriptor()
            bgPass.colorAttachments[0].texture     = colorTex
            bgPass.colorAttachments[0].loadAction  = .clear
            bgPass.colorAttachments[0].clearColor  = backgroundConfig.clearColor
            bgPass.colorAttachments[0].storeAction = .store
            if let bgEnc = commandBuffer.makeRenderCommandEncoder(descriptor: bgPass) {
                scenePipeline.encodeBackground(into: bgEnc, sceneCtx)
                bgEnc.endEncoding()
            }
        }

        // ── Feedback composite → colorTex ─────────────────────────────────────
        if feedbackActive, let fp = feedbackProc, let fs = feedbackSettings {
            fp.process(commandBuffer: commandBuffer, dest: colorTex, settings: fs,
                       excludeBackground: excludeBg)
        }

        // ── Feedback-off geometry (after composite, so no trails) ─────────────
        // Depth-tests/writes against the feedback pass's preserved scene depth.
        if feedbackActive, !visibleOff.isEmpty,
           let fp = feedbackProc, let depthTex = fp.depthTexture {
            let desc = MTLRenderPassDescriptor()
            desc.colorAttachments[0].texture     = colorTex
            desc.colorAttachments[0].loadAction  = .load
            desc.colorAttachments[0].storeAction = .store
            desc.depthAttachment.texture         = depthTex
            desc.depthAttachment.loadAction      = .load
            desc.depthAttachment.storeAction     = .store
            if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: desc) {
                let (offOpaque, offTransparent) = splitOpaqueTransparent(visibleOff)
                encodeOpaqueGeometry(offOpaque, into: enc)
                encodeTransparentGeometry(offTransparent, into: enc)
                enc.endEncoding()
            }
        }

        // ── Excluded beams + hit effects + all sparks (after feedback, no trails) ──
        // Depth-test against opaque-only fxDepth (falls back to feedback depth) so
        // beams behind window glass aren't depth-rejected.
        if includeLaserFX, feedbackActive, let fp = feedbackProc,
           let depthTex = fxDepth ?? fp.depthTexture {
            scenePipeline.encodeExcludedLaserBeams(commandBuffer: commandBuffer,
                                                   dest: colorTex, depthTex: depthTex, sceneCtx)
        }

        // ── Fog volume composite (last; fog + feedback coexist) ───────────────
        // Clamps to opaque-only fxDepth so glass doesn't cut fog off behind windows;
        // falls back to the per-mode scene depth if the pre-pass texture is absent.
        if fogSettings?.isEnabled == true {
            let fogDepth = fxDepth ?? (feedbackActive ? feedbackProc?.depthTexture : depthTex)
            if let fogTex = fogDepth {
                scenePipeline.encodeFogVolume(commandBuffer: commandBuffer,
                                              dest: colorTex, depthTex: fogTex, sceneCtx)
            }
        }

        // ── Axes gizmo overlay (bottom-right corner) ──────────────────────────
        if showAxesGizmo {
            drawGizmoPass(commandBuffer: commandBuffer, dest: colorTex)
        }

        // ── Color grade (brightness / contrast) ──────────────────────────────
        if let settings = colorGradeSettings, !settings.isIdentity,
           let gTex     = gradeTex {
            // Blit the rendered frame into the intermediate grade texture so the
            // fragment shader can sample it while writing back to colorTex.
            if let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.copy(from: colorTex, to: gTex)
                blit.endEncoding()
            }
            scenePipeline.encodeColorGrade(commandBuffer: commandBuffer,
                                           source: gTex, dest: colorTex, settings: settings)
        }

        // ── Luma alpha (ProRes 4444 color passes) ─────────────────────────────
        // Rewrites the alpha channel to Rec.709 luma of the RGB (RGB unchanged).
        // Matte (.blackWhite) and 422 passes skip this and keep the coverage alpha.
        if activeCodec == .proRes4444, colorMode == .color,
           let gTex     = gradeTex,
           let pipeline = lumaAlphaPipelineState {
            if let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.copy(from: colorTex, to: gTex)
                blit.endEncoding()
            }
            let lumaPass = MTLRenderPassDescriptor()
            lumaPass.colorAttachments[0].texture     = colorTex
            lumaPass.colorAttachments[0].loadAction  = .dontCare
            lumaPass.colorAttachments[0].storeAction = .store
            if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: lumaPass) {
                enc.setRenderPipelineState(pipeline)
                enc.setFragmentTexture(gTex, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                enc.endEncoding()
            }
        }

        // ── Blit color → staging; synchronize if needed for CPU readback ──────
        // colorTex's alpha holds either the coverage matte (matte/422 passes) or
        // the Rec.709 luma (4444 color passes); either way it copies straight through.
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(from: colorTex, to: stagingTex)
            if !device.hasUnifiedMemory {
                blit.synchronize(resource: stagingTex)  // required for .managed on discrete GPU
            }
            blit.endEncoding()
        }

        // Committed but NOT waited on here — the caller pipelines: it waits on the
        // returned buffer one frame later, after the GPU has had time to finish,
        // then does the getBytes readback.  The staging blit (+ synchronize for
        // managed memory) above guarantees the pixels are ready once it completes.
        commandBuffer.commit()
        return commandBuffer
    }

    /// Reads back a finished frame's staging texture and appends it to the writer.
    /// Called in FIFO order so presentation times stay monotonic.  The caller must
    /// have waited on the frame's command buffer before calling this.
    private func appendFrame(staging:          MTLTexture,
                             frameIndex:       Int,
                             presentationTime: CMTime,
                             adaptor:          AVAssetWriterInputPixelBufferAdaptor,
                             writerInput:      AVAssetWriterInput,
                             totalFrames:      Int,
                             progress:         @escaping (Float) -> Void) {
        // Copy staging texture → CVPixelBuffer (alpha already holds the coverage matte)
        guard let pb = pixelBufferFrom(staging,
                                       pool: adaptor.pixelBufferPool) else {
            print("[DEBUG] VideoExporter: frame " + String(frameIndex)
                + " — pixel buffer creation failed, skipping")
            return
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

    // (Laser beam / hit / spark + weather particle draws now live in ScenePipeline.)

    // MARK: - Probe marks (mirrors Renderer.drawMarks)

    /// Draws each visible mark as a small single-colour axis-cross + sphere into
    /// the scene encoder.  No selection highlight in export (no cycling there).
    private func drawMarksInEncoder(_ encoder: MTLRenderCommandEncoder,
                                    viewProjection vp: matrix_float4x4) {
        guard marksVisible, !marks.isEmpty, let pipeline = widgetPipelineState else { return }
        encoder.setRenderPipelineState(pipeline)
        if let ds = laserBeamDepthState { encoder.setDepthStencilState(ds) }
        encoder.setCullMode(.none)

        let len = max(0.4, min(camera.distance * 0.25, 1.5)) * 0.15
        for mark in marks {
            let c = SIMD4<Float>(mark.color, 1)
            let p = mark.position
            var xAxis = [p - SIMD3<Float>(len, 0, 0), p + SIMD3<Float>(len, 0, 0)]
            drawMarkLines(encoder, &xAxis, vp, c)
            var yAxis = [p - SIMD3<Float>(0, len, 0), p + SIMD3<Float>(0, len, 0)]
            drawMarkLines(encoder, &yAxis, vp, c)
            var zAxis = [p - SIMD3<Float>(0, 0, len), p + SIMD3<Float>(0, 0, len)]
            drawMarkLines(encoder, &zAxis, vp, c)
            var sphere = SceneWidgets.sphereWireframe(center: p, radius: len * 0.25)
            drawMarkLines(encoder, &sphere, vp, c)
        }
    }

    private func drawMarkLines(_ encoder: MTLRenderCommandEncoder,
                               _ vertices: inout [SIMD3<Float>],
                               _ vp: matrix_float4x4,
                               _ color: SIMD4<Float>) {
        guard !vertices.isEmpty else { return }
        encoder.setVertexBytes(&vertices,
                               length: MemoryLayout<SIMD3<Float>>.stride * vertices.count, index: 0)
        var u = WidgetUniforms(viewProjectionMatrix: vp, color: color)
        encoder.setVertexBytes(&u, length: MemoryLayout<WidgetUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: vertices.count)
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
                                  pool: CVPixelBufferPool?) -> CVPixelBuffer? {
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

        // ProRes 4444 color passes carry alpha = Rec.709 luma (written by the GPU
        // luma-alpha pass) with full, un-darkened RGB.  Tag the buffer Premultiplied
        // so the alpha mode propagates into the track format description and the RGB
        // displays at full brightness downstream (Straight would re-darken it by the
        // alpha).  Matte/422 passes keep their coverage alpha and the default tag.
        if activeCodec == .proRes4444 && colorMode == .color {
            CVBufferSetAttachment(buffer,
                                  kCVImageBufferAlphaChannelModeKey,
                                  kCVImageBufferAlphaChannelMode_PremultipliedAlpha,
                                  .shouldPropagate)
        }
        return buffer
    }

    // MARK: - Sync countdown

    private enum CountdownFrameKind {
        case number(Int)   // big centered digit on black
        case flash         // solid white alignment frame
    }

    /// Builds one countdown frame at the export resolution via CoreGraphics, so it
    /// matches the writer's pixel format exactly.  Opaque (alpha = 255) so it reads
    /// the same under any downstream alpha interpretation.
    private func makeCountdownPixelBuffer(kind: CountdownFrameKind) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey           as String: width,
            kCVPixelBufferHeightKey          as String: height
        ]
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                   attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let buffer = pb else {
            print("[DEBUG] VideoExporter: countdown CVPixelBufferCreate failed")
            return nil
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        // BGRA = 32-bit little-endian premultiplied-first.
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
                       | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: base, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: bitmapInfo) else {
            print("[DEBUG] VideoExporter: countdown CGContext failed")
            return nil
        }

        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        switch kind {
        case .flash:
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            ctx.fill(rect)

        case .number(let n):
            ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
            ctx.fill(rect)

            // Draw in CoreGraphics' native y-up space (no flip): a bitmap context's
            // top scanline lands in memory row 0, which is exactly how the video
            // pipeline reads the buffer, so the glyph comes out upright.
            let fontSize = CGFloat(height) * 0.4
            let font     = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
            let attrs: [NSAttributedString.Key: Any] = [
                .font:            font,
                .foregroundColor: CGColor(red: 1, green: 1, blue: 1, alpha: 1)
            ]
            let attr = NSAttributedString(string: String(n), attributes: attrs)
            let line = CTLineCreateWithAttributedString(attr)
            // Center the glyph: baseline placed so ascent/descent straddle the middle
            // (y increases upward).
            let ascent  = CTFontGetAscent(font)
            let descent = CTFontGetDescent(font)
            let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let tx = (CGFloat(width)  - lineWidth) / 2
            let ty = CGFloat(height) / 2 - (ascent - descent) / 2
            ctx.textPosition = CGPoint(x: tx, y: ty)
            CTLineDraw(line, ctx)
        }

        if activeCodec == .proRes4444 && colorMode == .color {
            CVBufferSetAttachment(buffer,
                                  kCVImageBufferAlphaChannelModeKey,
                                  kCVImageBufferAlphaChannelMode_PremultipliedAlpha,
                                  .shouldPropagate)
        }
        return buffer
    }

    /// Appends a pre-built pixel buffer (countdown frame) at the given time, waiting
    /// for the writer input to be ready.  Mirrors appendFrame's readiness loop.
    private func appendPixelBuffer(_ pb: CVPixelBuffer,
                                   at presentationTime: CMTime,
                                   adaptor: AVAssetWriterInputPixelBufferAdaptor,
                                   writerInput: AVAssetWriterInput) {
        var waitCount = 0
        while !writerInput.isReadyForMoreMediaData {
            Thread.sleep(forTimeInterval: 0.002)
            waitCount += 1
            if waitCount > 500 { break }
        }
        if writerInput.isReadyForMoreMediaData {
            adaptor.append(pb, withPresentationTime: presentationTime)
        }
    }

    // MARK: - Animation (independent of Timeline.currentTime)

    // Evaluates keyframes at the given time and writes directly to object transforms.
    // Does NOT modify timeline.currentTime — the live UI is unaffected during export.
    private func applyAnimation(at time: Double) {
        // Past-duration cutoff for fog/particle keyframe evaluation (renderState),
        // matching the live renderer + object/camera/light.
        fogSettings?.evaluationCutoff = timelineDuration
        particleManager?.emitters.forEach { $0.evaluationCutoff = timelineDuration }

        // ── Object transforms ─────────────────────────────────────────────────
        for object in sceneManager.objects {
            guard let track = object.keyframeTrack,
                  !track.keyframes.isEmpty else { continue }
            if let delta = track.evaluate(at: time, cutoff: timelineDuration) {
                if object.parentIndex != nil {
                    // Hierarchical part: baseTransform is a LOCAL transform; write
                    // localTransform and let applyHierarchy() below compute world transform.
                    object.localTransform = object.baseTransform * delta
                } else {
                    // Root / non-hierarchical: animate world transform directly.
                    object.transform = object.baseTransform * delta
                }
            }
            // Opacity rides on the same keyframes — mirror the live Renderer's
            // applyAnimation so exported frames fade identically to the preview.
            if let op = track.evaluateOpacity(at: time, cutoff: timelineDuration) {
                object.material.opacity = op
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
            if let delta = track.evaluate(at: time, cutoff: timelineDuration) {
                sceneManager.groupTransforms[gid] = delta
            }
        }

        // Glued (enveloped) groups — mirrors Renderer.composeEnvelopedGroups().
        for (gid, link) in sceneManager.groupEnvelopeParent {
            guard link.env >= 0, link.env < objects.count else { continue }
            sceneManager.groupTransforms[gid] = objects[link.env].transform * link.local
        }

        // ── Camera ────────────────────────────────────────────────────────────
        // Evaluated here so the gizmo and view/projection matrices track the
        // animation correctly.  CameraController is NOT ObservableObject, so
        // writing its properties from the export background queue is safe.
        // Cut schedule: point the live camera at the program camera's track (so the
        // evaluation + follow below come from it) and seed a static program pose.
        if !cameraCuts.isEmpty, !cameras.isEmpty {
            let pc = cameras[programCameraIndex(at: time)]
            camera.keyframeTrack = pc.keyframeTrack
            if pc.keyframeTrack?.keyframes.isEmpty ?? true {
                camera.yaw = pc.yaw; camera.pitch = pc.pitch; camera.distance = pc.distance
                camera.target = pc.target; camera.fovYRadians = pc.fovYRadians
            }
        }
        if let camTrack = camera.keyframeTrack, !camTrack.keyframes.isEmpty {
            if let state = camTrack.evaluate(at: time, cutoff: timelineDuration) {
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
        // Evaluate into the non-published exportLights copy (not the @Published
        // lightManager.lights), so the SwiftUI inspector doesn't churn and this
        // runs on the export queue without a main-thread hop.  keyframeTracks is
        // a plain array, safe to read here; the MTKView is paused so there is no
        // concurrent reader of exportLights.
        for i in 0..<exportLights.count {
            guard i < lightManager.keyframeTracks.count,
                  let track = lightManager.keyframeTracks[i],
                  !track.keyframes.isEmpty else { continue }
            if let state = track.evaluate(at: time, cutoff: timelineDuration) {
                exportLights[i].intensity     = state.intensity
                exportLights[i].color         = state.color
                exportLights[i].position      = state.position
                exportLights[i].target        = state.target
                exportLights[i].range         = state.range
                exportLights[i].beamThickness = state.beamThickness
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
