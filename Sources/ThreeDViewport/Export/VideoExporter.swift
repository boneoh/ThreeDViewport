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
}

final class VideoExporter {

    // MARK: - Export resolution (must match viewport)

    let width:  Int = 1920
    let height: Int = 1080

    // MARK: - Private dependencies

    private let device:            MTLDevice
    private let commandQueue:      MTLCommandQueue
    private let sceneManager:      SceneManager
    private let camera:            CameraController
    private let lightManager:      LightManager
    private let backgroundConfig:  BackgroundConfig
    private let pipelineState:     MTLRenderPipelineState
    private let depthStencilState: MTLDepthStencilState
    private let animDuration:      Double
    private let frameRate:         Double

    // Phase 8+: rendering options matching the live display
    var isColorMode:   Bool = false
    var isWireframe:   Bool = false
    var showAxesGizmo: Bool = false

    // Background gradient pipeline (mirrors Renderer's background pipeline)
    private var backgroundPipelineState: MTLRenderPipelineState?
    private var backgroundDepthState:    MTLDepthStencilState?

    // Feedback settings — nil means no feedback during export
    var feedbackSettings: FeedbackSettings?

    // Fallback buffers for objects without UVs / tangents
    private var dummyUVBuffer:      MTLBuffer?
    private var dummyTangentBuffer: MTLBuffer?

    // Gizmo pipeline — built lazily from the same Metal library as the scene pipeline
    private var gizmoPipelineState: MTLRenderPipelineState?

    // MARK: - Init

    init?(device:            MTLDevice,
          commandQueue:      MTLCommandQueue,
          sceneManager:      SceneManager,
          camera:            CameraController,
          lightManager:      LightManager,
          backgroundConfig:  BackgroundConfig,
          timeline:          Timeline,
          pipelineState:     MTLRenderPipelineState,
          depthStencilState: MTLDepthStencilState) {

        self.device            = device
        self.commandQueue      = commandQueue
        self.sceneManager      = sceneManager
        self.camera            = camera
        self.lightManager      = lightManager
        self.backgroundConfig  = backgroundConfig
        self.pipelineState     = pipelineState
        self.depthStencilState = depthStencilState
        self.animDuration      = timeline.duration
        self.frameRate         = timeline.frameRate

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

            let timescale = CMTimeScale(self.frameRate)

            for frameIndex in 0..<totalFrames {
                let t               = Double(frameIndex) / self.frameRate
                let presentationTime = CMTime(value: CMTimeValue(frameIndex),
                                              timescale: timescale)

                // Evaluate animation at this exact time — does NOT touch Timeline.currentTime
                self.applyAnimation(at: t)

                // Render to offscreen texture (via feedback if enabled) and blit to staging
                self.renderFrame(colorTex:        colorTex,
                                 stagingTex:       stagingTex,
                                 depthTex:         depthTex,
                                 feedbackProc:     exportFeedback,
                                 feedbackSettings: self.feedbackSettings)

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

    private func makeDepthTexture() -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        desc.usage       = .renderTarget
        desc.storageMode = .private
        let t = device.makeTexture(descriptor: desc)
        if t == nil { print("[DEBUG] VideoExporter: makeDepthTexture returned nil") }
        return t
    }

    // MARK: - Offscreen render

    private func renderFrame(colorTex:        MTLTexture,
                             stagingTex:       MTLTexture,
                             depthTex:         MTLTexture,
                             feedbackProc:     FeedbackProcessor? = nil,
                             feedbackSettings: FeedbackSettings?  = nil) {
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
        passDesc.depthAttachment.storeAction      = .dontCare
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

            // ── Scene geometry ────────────────────────────────────────────────
            encoder.setRenderPipelineState(pipelineState)
            encoder.setDepthStencilState(depthStencilState)
            encoder.setTriangleFillMode(isWireframe ? .lines : .fill)

            // LightUniforms — constant across all objects
            var lightUniforms = lightManager.buildLightUniforms()
            encoder.setFragmentBytes(&lightUniforms,
                                     length: MemoryLayout<LightUniforms>.stride,
                                     index: 3)

            let vp  = camera.viewProjectionMatrix
            let eye = camera.eyePosition

            for object in sceneManager.objects {
                guard object.isVisible,
                      let posBuffer = object.positionBuffer,
                      let idxBuffer = object.indexBuffer,
                      object.indexCount > 0 else { continue }

                let normalMatrix = simd_transpose(simd_inverse(object.transform))
                var uniforms = Uniforms(
                    modelMatrix:          object.transform,
                    viewProjectionMatrix: vp,
                    normalMatrix:         normalMatrix,
                    cameraPosition:       SIMD4<Float>(eye.x, eye.y, eye.z, 0)
                )

                encoder.setVertexBuffer(posBuffer, offset: 0, index: 0)
                if let n = object.normalBuffer { encoder.setVertexBuffer(n, offset: 0, index: 1) }
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)

                let uvBuf  = object.uvBuffer      ?? dummyUVBuffer
                let tanBuf = object.tangentBuffer ?? dummyTangentBuffer
                encoder.setVertexBuffer(uvBuf,  offset: 0, index: 4)
                encoder.setVertexBuffer(tanBuf, offset: 0, index: 5)

                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)

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
                encoder.setFragmentBytes(&mu, length: MemoryLayout<MaterialUniforms>.stride, index: 4)

                if let t = mat.baseColorTexture          { encoder.setFragmentTexture(t, index: 0) }
                if let t = mat.normalTexture             { encoder.setFragmentTexture(t, index: 1) }
                if let t = mat.metallicRoughnessTexture  { encoder.setFragmentTexture(t, index: 2) }
                if let t = mat.emissiveTexture           { encoder.setFragmentTexture(t, index: 3) }

                encoder.drawIndexedPrimitives(
                    type: .triangle, indexCount: object.indexCount,
                    indexType: .uint32, indexBuffer: idxBuffer, indexBufferOffset: 0)
            }
            encoder.endEncoding()
        }

        // ── Feedback composite → colorTex ─────────────────────────────────────
        if feedbackActive, let fp = feedbackProc, let fs = feedbackSettings {
            fp.process(commandBuffer: commandBuffer, dest: colorTex, settings: fs)
        }

        // ── Axes gizmo overlay (bottom-right corner) ──────────────────────────
        if showAxesGizmo {
            drawGizmoPass(commandBuffer: commandBuffer, dest: colorTex)
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

    // Evaluates keyframes at the given time and writes directly to object.transform.
    // Does NOT modify timeline.currentTime — the live UI is unaffected during export.
    private func applyAnimation(at time: Double) {
        for object in sceneManager.objects {
            guard let track = object.keyframeTrack,
                  !track.keyframes.isEmpty else { continue }
            if let delta = track.evaluate(at: time) {
                object.transform = object.baseTransform * delta
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
