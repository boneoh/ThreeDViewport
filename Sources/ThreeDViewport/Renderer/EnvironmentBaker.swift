import Metal
import simd

// Bakes the current scene, seen from a probe point, into an equirectangular HDR.
//
// Renders the visible lit scene (optionally over the current environment backdrop)
// into 6 gnomonic faces from the probe, converts faces → equirect with the same
// basis vectors used to render (so orientation can't drift), reads the result
// back, and writes a Radiance .hdr.  A static, deterministic snapshot — re-bake
// to change.  Never touches the live render state.
enum EnvironmentBaker {

    private struct FaceDef { let forward: SIMD3<Float>; let up: SIMD3<Float> }

    // ±X / ±Y / ±Z look directions with non-parallel up hints.  `right`/`up` are
    // derived via the lookAt convention and shared with the conversion kernel.
    private static let faceDefs: [FaceDef] = [
        FaceDef(forward: SIMD3( 1, 0, 0), up: SIMD3(0, 1,  0)),
        FaceDef(forward: SIMD3(-1, 0, 0), up: SIMD3(0, 1,  0)),
        FaceDef(forward: SIMD3( 0, 1, 0), up: SIMD3(0, 0, -1)),
        FaceDef(forward: SIMD3( 0,-1, 0), up: SIMD3(0, 0,  1)),
        FaceDef(forward: SIMD3( 0, 0, 1), up: SIMD3(0, 1,  0)),
        FaceDef(forward: SIMD3( 0, 0,-1), up: SIMD3(0, 1,  0)),
    ]

    /// Bakes to `url`.  `width`×`height` is the equirect resolution (2:1).
    /// `includeBackground` captures the current environment behind the geometry;
    /// otherwise geometry sits on black.  Returns true on success.
    @discardableResult
    static func bake(to url: URL,
                     width: Int,
                     height: Int,
                     probePosition: SIMD3<Float>,
                     includeBackground: Bool,
                     backgroundIntensity: Float,
                     backgroundHorizon:   Float,
                     device: MTLDevice,
                     sceneManager: SceneManager,
                     lightManager: LightManager,
                     ibl: IBL?,
                     backgroundEquirect: MTLTexture?) -> Bool {

        guard let library = try? device.makeDefaultLibrary(bundle: Bundle.module),
              let commandQueue = device.makeCommandQueue() else { return false }

        let faceSize = max(256, width / 4)   // ≈ equator pixels per 90° face

        // ── Pipelines + states (HDR rgba16Float targets) ──────────────────────
        // SPIKE: fragment_main carries a USE_RT function constant — specialize false.
        let fcFalse = MTLFunctionConstantValues()
        var rtOff = false
        fcFalse.setConstantValue(&rtOff, type: .bool, index: 0)
        guard let vfn = library.makeFunction(name: "vertex_main"),
              let ffn = try? library.makeFunction(name: "fragment_main", constantValues: fcFalse) else { return false }
        let scenePD = MTLRenderPipelineDescriptor()
        scenePD.vertexFunction   = vfn
        scenePD.fragmentFunction = ffn
        scenePD.colorAttachments[0].pixelFormat = .rgba16Float
        scenePD.depthAttachmentPixelFormat      = .depth32Float
        guard let scenePipe = try? device.makeRenderPipelineState(descriptor: scenePD) else { return false }

        var skyPipe: MTLRenderPipelineState?
        if includeBackground,
           let svfn = library.makeFunction(name: "skybox_vertex"),
           let sffn = library.makeFunction(name: "skybox_fragment") {
            let skyPD = MTLRenderPipelineDescriptor()
            skyPD.vertexFunction   = svfn
            skyPD.fragmentFunction = sffn
            skyPD.colorAttachments[0].pixelFormat = .rgba16Float
            skyPD.depthAttachmentPixelFormat      = .depth32Float
            skyPipe = try? device.makeRenderPipelineState(descriptor: skyPD)
        }

        let sceneDD = MTLDepthStencilDescriptor()
        sceneDD.depthCompareFunction = .less
        sceneDD.isDepthWriteEnabled  = true
        guard let sceneDepth = device.makeDepthStencilState(descriptor: sceneDD) else { return false }

        let skyDD = MTLDepthStencilDescriptor()
        skyDD.depthCompareFunction = .always
        skyDD.isDepthWriteEnabled  = false
        let skyDepth = device.makeDepthStencilState(descriptor: skyDD)

        // Fallback vertex buffers the scene encoder always binds.
        var dummyUV:  [Float] = [0, 0]
        var dummyTan: [Float] = [1, 0, 0, 1]
        let dummyUVBuf  = device.makeBuffer(bytes: &dummyUV,  length: 8,  options: .storageModeShared)
        let dummyTanBuf = device.makeBuffer(bytes: &dummyTan, length: 16, options: .storageModeShared)
        // 1×1 placeholder for the skybox's equirect slot when there's no equirect.
        let dEqD = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
        dEqD.usage = [.shaderRead]
        let dummyEq = device.makeTexture(descriptor: dEqD)

        // ── Targets: 6-slice HDR face array + shared depth ────────────────────
        let arrD = MTLTextureDescriptor()
        arrD.textureType = .type2DArray
        arrD.pixelFormat = .rgba16Float
        arrD.width = faceSize; arrD.height = faceSize
        arrD.arrayLength = 6
        arrD.usage = [.renderTarget, .shaderRead]
        arrD.storageMode = .private
        guard let faceArray = device.makeTexture(descriptor: arrD) else { return false }

        let depthD = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: faceSize, height: faceSize, mipmapped: false)
        depthD.usage = [.renderTarget]
        depthD.storageMode = .private
        guard let depthTex = device.makeTexture(descriptor: depthD) else { return false }

        let proj          = makePerspective(fovY: .pi / 2, aspect: 1, near: 0.01, far: 2000)
        let lightUniforms = lightManager.buildLightUniforms()
        let visible       = sceneManager.objects.filter { $0.isVisible }

        guard let cmd = commandQueue.makeCommandBuffer() else { return false }

        // ── Render the 6 faces ────────────────────────────────────────────────
        var bases: [FaceBasis] = []
        for (i, fd) in faceDefs.enumerated() {
            let f = simd_normalize(fd.forward)
            let r = simd_normalize(simd_cross(f, fd.up))
            let u = simd_cross(r, f)
            bases.append(FaceBasis(forward: SIMD4(f, 0), right: SIMD4(r, 0), up: SIMD4(u, 0)))

            let view = makeLookAt(eye: probePosition, center: probePosition + f, up: fd.up)
            let vp   = proj * view

            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture     = faceArray
            pass.colorAttachments[0].slice       = i
            pass.colorAttachments[0].loadAction  = .clear
            pass.colorAttachments[0].clearColor  = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            pass.colorAttachments[0].storeAction = .store
            pass.depthAttachment.texture     = depthTex
            pass.depthAttachment.loadAction  = .clear
            pass.depthAttachment.clearDepth  = 1.0
            pass.depthAttachment.storeAction = .dontCare

            guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return false }

            // Environment backdrop (optional), then the lit scene over it.
            if includeBackground, let skyPipe, let cube = ibl?.envCubemap {
                let eq = backgroundEquirect ?? ibl?.envEquirect
                enc.setRenderPipelineState(skyPipe)
                if let skyDepth { enc.setDepthStencilState(skyDepth) }
                enc.setCullMode(.none)
                var sky = SkyboxUniforms(
                    inverseViewProjection: simd_inverse(vp),
                    cameraPos:             SIMD4(probePosition, 1),
                    intensity:             backgroundIntensity,
                    horizon:               backgroundHorizon,   // WYSIWYG with the viewport
                    useEquirect:           eq != nil ? 1 : 0,
                    colorMode:             UInt32(RenderColorMode.color.rawValue))
                enc.setFragmentBytes(&sky, length: MemoryLayout<SkyboxUniforms>.stride, index: 0)
                enc.setFragmentTexture(cube, index: 0)
                enc.setFragmentTexture(eq ?? dummyEq, index: 1)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }

            SceneGeometryEncoder.encode(
                into:            enc,
                objects:         visible,
                groupTransforms: sceneManager.groupTransforms,
                lightUniforms:   lightUniforms,
                context: SceneGeometryEncoder.Context(
                    viewProjection:    vp,
                    eyePosition:       probePosition,
                    pipelineState:     scenePipe,
                    depthStencilState: sceneDepth,
                    colorMode:         .color,   // full-colour radiance, ignore matte/greyscale
                    isWireframe:       false,
                    exposure:          1.0,      // raw linear radiance, no view grade
                    ibl:               ibl,
                    dummyUV:           dummyUVBuf,
                    dummyTangent:      dummyTanBuf,
                    dummy2D:           dummyEq))

            enc.endEncoding()
        }

        // ── Faces → equirect (rgba32Float, CPU-readable) ──────────────────────
        let eqD = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        eqD.usage       = [.shaderWrite, .shaderRead]
        eqD.storageMode = .shared
        guard let eqTex = device.makeTexture(descriptor: eqD) else { return false }

        guard let kfn  = library.makeFunction(name: "cube_to_equirect_kernel"),
              let kpipe = try? device.makeComputePipelineState(function: kfn),
              let cenc  = cmd.makeComputeCommandEncoder() else { return false }
        cenc.setComputePipelineState(kpipe)
        cenc.setTexture(faceArray, index: 0)
        cenc.setTexture(eqTex,     index: 1)
        cenc.setBytes(&bases, length: MemoryLayout<FaceBasis>.stride * bases.count, index: 0)
        cenc.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                             threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        cenc.endEncoding()

        cmd.commit()
        cmd.waitUntilCompleted()

        // ── Read back + write .hdr ────────────────────────────────────────────
        var floats = [Float](repeating: 0, count: width * height * 4)
        floats.withUnsafeMutableBytes { raw in
            eqTex.getBytes(raw.baseAddress!,
                           bytesPerRow: width * 4 * MemoryLayout<Float>.size,
                           from: MTLRegionMake2D(0, 0, width, height),
                           mipmapLevel: 0)
        }
        return HDRWriter.write(rgba: floats, width: width, height: height, to: url)
    }

    // MARK: - Math (Metal-style, matches CameraController)

    private static func makeLookAt(eye: SIMD3<Float>,
                                   center: SIMD3<Float>,
                                   up: SIMD3<Float>) -> matrix_float4x4 {
        let f = simd_normalize(center - eye)
        let r = simd_normalize(simd_cross(f, up))
        let u = simd_cross(r, f)
        return matrix_float4x4(columns: (
            SIMD4<Float>( r.x,  u.x, -f.x, 0),
            SIMD4<Float>( r.y,  u.y, -f.y, 0),
            SIMD4<Float>( r.z,  u.z, -f.z, 0),
            SIMD4<Float>(-simd_dot(r, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)
        ))
    }

    private static func makePerspective(fovY: Float, aspect: Float,
                                        near: Float, far: Float) -> matrix_float4x4 {
        let ys = 1.0 / tan(fovY * 0.5)
        let xs = ys / aspect
        let zs = far / (near - far)
        return matrix_float4x4(columns: (
            SIMD4<Float>(xs,  0,  0,  0),
            SIMD4<Float>( 0, ys,  0,  0),
            SIMD4<Float>( 0,  0, zs, -1),
            SIMD4<Float>( 0,  0, near * zs, 0)
        ))
    }
}
