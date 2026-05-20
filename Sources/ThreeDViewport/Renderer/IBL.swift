import Metal
import simd

// Phase C: image-based lighting precompute and resources.
// Owns the BRDF integration LUT, irradiance cubemap, and prefiltered specular
// cubemap.  Generated once at Renderer init via Metal compute pipelines; the
// resulting MTLTextures are bound to the scene fragment shader every frame.
//
// Phases done: 1 (BRDF LUT), 2 (env cubemap), 3 (irradiance cubemap),
// 4 (prefiltered specular cubemap).
final class IBL {

    let device:       MTLDevice
    private let queue: MTLCommandQueue

    // ── Generated resources ───────────────────────────────────────────────────
    private(set) var brdfLUT:        MTLTexture?
    private(set) var envCubemap:     MTLTexture?    // raw procedural sky
    private(set) var irradianceCube: MTLTexture?    // diffuse-convolved env
    private(set) var specularCube:   MTLTexture?    // prefiltered, mip = roughness

    // Global intensity multiplier (applied at sample time in the fragment shader).
    var intensity: Float = 1.0

    // Texture sizes — small constants kept here so callers can reason about cost.
    private static let brdfLUTSize     = 256
    private static let envCubeSize     = 256
    private static let irradianceSize  = 32        // low-frequency, 32² is plenty
    private static let specularSize    = 128       // mip 0 size; mips down by half
    private static let specularMipCount = 5        // → roughness 0.00, 0.25, 0.50, 0.75, 1.00

    // Bundled equirectangular HDR used as the environment.  Falls back to the
    // procedural sky if this resource is missing or unreadable.
    private static let environmentHDRName = "brown_photostudio_02_2k"

    // CPU mirror of the procedural sky parameters.  Must match
    // `struct EnvSkyParams` in IBLShaders.metal exactly.
    struct EnvSkyParams {
        var topColor:     SIMD4<Float>
        var horizonColor: SIMD4<Float>
        var bottomColor:  SIMD4<Float>
        var sunDir:       SIMD4<Float>
        var sunColor:     SIMD4<Float>   // w = cos(angularRadius)
    }

    // Defaults: cool studio-ish look.  Linear-space colours.
    private static let defaultSkyParams: EnvSkyParams = {
        let sunDir = simd_normalize(SIMD3<Float>(0.4, 0.7, 0.3))
        return EnvSkyParams(
            topColor:     SIMD4<Float>(0.55, 0.70, 0.95, 0),
            horizonColor: SIMD4<Float>(0.90, 0.90, 0.92, 0),
            bottomColor:  SIMD4<Float>(0.12, 0.12, 0.14, 0),
            sunDir:       SIMD4<Float>(sunDir.x, sunDir.y, sunDir.z, 0),
            sunColor:     SIMD4<Float>(8.0, 7.5, 6.5, 0.9995)  // w = cos(~1.8°)
        )
    }()

    init?(device: MTLDevice, library: MTLLibrary, commandQueue: MTLCommandQueue) {
        self.device = device
        self.queue  = commandQueue

        guard let lut = Self.generateBRDFLUT(device:        device,
                                              library:       library,
                                              commandQueue:  commandQueue) else {
            print("[DEBUG] IBL: BRDF LUT generation failed")
            return nil
        }
        self.brdfLUT = lut
        print("[DEBUG] IBL: BRDF LUT ready (\(Self.brdfLUTSize)×\(Self.brdfLUTSize) RG16F)")

        // Prefer the bundled HDR studio environment; fall back to procedural sky.
        let env = Self.loadHDREnvCubemap(device:       device,
                                          library:      library,
                                          commandQueue: commandQueue)
               ?? Self.generateEnvCubemap(device:       device,
                                          library:      library,
                                          commandQueue: commandQueue,
                                          params:       Self.defaultSkyParams)
        guard let env else {
            print("[DEBUG] IBL: env cubemap generation failed (HDR and procedural)")
            return nil
        }
        self.envCubemap = env
        print("[DEBUG] IBL: env cubemap ready (\(Self.envCubeSize)² × 6, RGBA16F)")

        guard let irr = Self.generateIrradianceCubemap(device:       device,
                                                       library:      library,
                                                       commandQueue: commandQueue,
                                                       envCubemap:   env) else {
            print("[DEBUG] IBL: irradiance cubemap generation failed")
            return nil
        }
        self.irradianceCube = irr
        print("[DEBUG] IBL: irradiance cubemap ready (\(Self.irradianceSize)² × 6, RGBA16F)")

        guard let spec = Self.generateSpecularCubemap(device:       device,
                                                       library:      library,
                                                       commandQueue: commandQueue,
                                                       envCubemap:   env) else {
            print("[DEBUG] IBL: specular cubemap generation failed")
            return nil
        }
        self.specularCube = spec
        print("[DEBUG] IBL: prefiltered specular ready "
            + "(\(Self.specularSize)² × 6, \(Self.specularMipCount) mips, RGBA16F)")
    }

    // MARK: - BRDF LUT precompute

    private static func generateBRDFLUT(device:       MTLDevice,
                                         library:      MTLLibrary,
                                         commandQueue: MTLCommandQueue) -> MTLTexture? {
        let size = brdfLUTSize

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rg16Float,
            width:       size,
            height:      size,
            mipmapped:   false)
        desc.usage       = [.shaderRead, .shaderWrite]
        desc.storageMode = .private

        guard let texture = device.makeTexture(descriptor: desc) else {
            print("[DEBUG] IBL: brdfLUT makeTexture failed")
            return nil
        }
        texture.label = "IBL_BRDF_LUT"

        guard let kernel = library.makeFunction(name: "brdf_lut_kernel") else {
            print("[DEBUG] IBL: brdf_lut_kernel not found in library")
            return nil
        }

        let pipeline: MTLComputePipelineState
        do {
            pipeline = try device.makeComputePipelineState(function: kernel)
        } catch {
            print("[DEBUG] IBL: makeComputePipelineState failed — \(error)")
            return nil
        }

        guard let cmd = commandQueue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else {
            print("[DEBUG] IBL: command buffer / encoder nil")
            return nil
        }
        enc.label = "IBL.brdfLUT"
        enc.setComputePipelineState(pipeline)
        enc.setTexture(texture, index: 0)

        let tg   = MTLSize(width: 8, height: 8, depth: 1)
        let grid = MTLSize(width: size, height: size, depth: 1)
        enc.dispatchThreads(grid, threadsPerThreadgroup: tg)
        enc.endEncoding()

        cmd.commit()
        cmd.waitUntilCompleted()         // blocking — runs once at startup
        return texture
    }

    // MARK: - HDR environment loading

    // Resolves which HDR to load: a user-configured path from AppSettings if set
    // and present on disk, otherwise the bundled default.  Returns nil only when
    // neither is available (caller then falls back to procedural).
    private static func resolveHDRURL() -> URL? {
        let configured = AppSettings.shared.hdrPath
        if !configured.isEmpty {
            let url = AppSettings.expand(configured)
            if FileManager.default.fileExists(atPath: url.path) {
                print("[DEBUG] IBL: using configured HDR " + url.path)
                return url
            }
            print("[DEBUG] IBL: configured HDR not found (" + url.path + ") — bundled fallback")
        }
        return Bundle.module.url(forResource: environmentHDRName, withExtension: "hdr")
    }

    // Loads the bundled equirectangular HDR and projects it into the env cubemap.
    // Returns nil (so the caller falls back to procedural) if the resource is
    // missing, unparseable, or any Metal step fails.
    private static func loadHDREnvCubemap(device:       MTLDevice,
                                          library:      MTLLibrary,
                                          commandQueue: MTLCommandQueue) -> MTLTexture? {
        guard let url = resolveHDRURL() else {
            print("[DEBUG] IBL: no HDR available — procedural fallback")
            return nil
        }
        guard let hdr = HDRImage(url: url) else {
            print("[DEBUG] IBL: HDR parse failed — procedural fallback")
            return nil
        }
        print("[DEBUG] IBL: HDR loaded \(hdr.width)×\(hdr.height) (\(environmentHDRName))")

        // Upload equirect as a CPU-writable RGBA32F 2D texture.
        let eqDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width:  hdr.width,
            height: hdr.height,
            mipmapped: false)
        eqDesc.usage       = [.shaderRead]
        eqDesc.storageMode = .shared
        guard let eqTex = device.makeTexture(descriptor: eqDesc) else {
            print("[DEBUG] IBL: equirect makeTexture failed")
            return nil
        }
        eqTex.label = "IBL_EquirectHDR"
        hdr.rgba.withUnsafeBytes { raw in
            eqTex.replace(region:      MTLRegionMake2D(0, 0, hdr.width, hdr.height),
                          mipmapLevel: 0,
                          withBytes:   raw.baseAddress!,
                          bytesPerRow: hdr.width * 4 * MemoryLayout<Float>.size)
        }

        // Destination env cubemap.
        let desc = MTLTextureDescriptor()
        desc.textureType      = .typeCube
        desc.pixelFormat      = .rgba16Float
        desc.width            = envCubeSize
        desc.height           = envCubeSize
        desc.mipmapLevelCount = 1
        desc.usage            = [.shaderRead, .shaderWrite]
        desc.storageMode      = .private
        guard let cube = device.makeTexture(descriptor: desc) else {
            print("[DEBUG] IBL: HDR env cube makeTexture failed")
            return nil
        }
        cube.label = "IBL_EnvCubemap(HDR)"

        guard let kernel = library.makeFunction(name: "equirect_to_cube_kernel"),
              let pipeline = try? device.makeComputePipelineState(function: kernel) else {
            print("[DEBUG] IBL: equirect_to_cube pipeline failed")
            return nil
        }
        guard let cmd = commandQueue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { return nil }
        enc.label = "IBL.equirectToCube"
        enc.setComputePipelineState(pipeline)
        enc.setTexture(cube,  index: 0)
        enc.setTexture(eqTex, index: 1)
        let tg   = MTLSize(width: 8, height: 8, depth: 1)
        let grid = MTLSize(width: envCubeSize, height: envCubeSize, depth: 6)
        enc.dispatchThreads(grid, threadsPerThreadgroup: tg)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        return cube
    }

    // MARK: - Environment cubemap precompute (procedural fallback)

    private static func generateEnvCubemap(device:       MTLDevice,
                                            library:      MTLLibrary,
                                            commandQueue: MTLCommandQueue,
                                            params:       EnvSkyParams) -> MTLTexture? {
        let size = envCubeSize

        let desc = MTLTextureDescriptor()
        desc.textureType = .typeCube
        desc.pixelFormat = .rgba16Float
        desc.width       = size
        desc.height      = size
        desc.mipmapLevelCount = 1
        desc.usage       = [.shaderRead, .shaderWrite]
        desc.storageMode = .private

        guard let texture = device.makeTexture(descriptor: desc) else {
            print("[DEBUG] IBL: envCubemap makeTexture failed")
            return nil
        }
        texture.label = "IBL_EnvCubemap"

        guard let kernel = library.makeFunction(name: "env_cube_kernel") else {
            print("[DEBUG] IBL: env_cube_kernel not found")
            return nil
        }
        let pipeline: MTLComputePipelineState
        do {
            pipeline = try device.makeComputePipelineState(function: kernel)
        } catch {
            print("[DEBUG] IBL: env_cube pipeline failed — \(error)")
            return nil
        }

        guard let cmd = commandQueue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { return nil }
        enc.label = "IBL.envCube"
        enc.setComputePipelineState(pipeline)
        enc.setTexture(texture, index: 0)

        // Sky params passed inline via setBytes — 80 B, well under the 4 KB limit.
        var p = params
        enc.setBytes(&p, length: MemoryLayout<EnvSkyParams>.stride, index: 0)

        let tg   = MTLSize(width: 8, height: 8, depth: 1)
        let grid = MTLSize(width: size, height: size, depth: 6)
        enc.dispatchThreads(grid, threadsPerThreadgroup: tg)
        enc.endEncoding()

        cmd.commit()
        cmd.waitUntilCompleted()
        return texture
    }

    // MARK: - Irradiance cubemap precompute

    private static func generateIrradianceCubemap(device:       MTLDevice,
                                                   library:      MTLLibrary,
                                                   commandQueue: MTLCommandQueue,
                                                   envCubemap:   MTLTexture) -> MTLTexture? {
        let size = irradianceSize

        let desc = MTLTextureDescriptor()
        desc.textureType = .typeCube
        desc.pixelFormat = .rgba16Float
        desc.width       = size
        desc.height      = size
        desc.mipmapLevelCount = 1
        desc.usage       = [.shaderRead, .shaderWrite]
        desc.storageMode = .private

        guard let texture = device.makeTexture(descriptor: desc) else {
            print("[DEBUG] IBL: irradianceCube makeTexture failed")
            return nil
        }
        texture.label = "IBL_IrradianceCube"

        guard let kernel = library.makeFunction(name: "irradiance_cube_kernel") else {
            print("[DEBUG] IBL: irradiance_cube_kernel not found")
            return nil
        }
        let pipeline: MTLComputePipelineState
        do {
            pipeline = try device.makeComputePipelineState(function: kernel)
        } catch {
            print("[DEBUG] IBL: irradiance pipeline failed — \(error)")
            return nil
        }

        guard let cmd = commandQueue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { return nil }
        enc.label = "IBL.irradianceCube"
        enc.setComputePipelineState(pipeline)
        enc.setTexture(texture,    index: 0)
        enc.setTexture(envCubemap, index: 1)

        let tg   = MTLSize(width: 8, height: 8, depth: 1)
        let grid = MTLSize(width: size, height: size, depth: 6)
        enc.dispatchThreads(grid, threadsPerThreadgroup: tg)
        enc.endEncoding()

        cmd.commit()
        cmd.waitUntilCompleted()
        return texture
    }

    // MARK: - Prefiltered specular cubemap precompute

    private static func generateSpecularCubemap(device:       MTLDevice,
                                                 library:      MTLLibrary,
                                                 commandQueue: MTLCommandQueue,
                                                 envCubemap:   MTLTexture) -> MTLTexture? {
        let baseSize = specularSize
        let numMips  = specularMipCount

        let desc = MTLTextureDescriptor()
        desc.textureType      = .typeCube
        desc.pixelFormat      = .rgba16Float
        desc.width            = baseSize
        desc.height           = baseSize
        desc.mipmapLevelCount = numMips
        desc.usage            = [.shaderRead, .pixelFormatView]   // pixelFormatView lets us makeTextureView
        desc.storageMode      = .private

        // Compute writes need .shaderWrite *on the view we bind*; Metal allows that
        // even when the parent texture lacks it as long as we use a view of one
        // mip with .shaderWrite usage.  Easiest: just add .shaderWrite to the parent.
        desc.usage = [.shaderRead, .shaderWrite, .pixelFormatView]

        guard let texture = device.makeTexture(descriptor: desc) else {
            print("[DEBUG] IBL: specularCube makeTexture failed")
            return nil
        }
        texture.label = "IBL_SpecularCube"

        guard let kernel = library.makeFunction(name: "prefilter_cube_kernel") else {
            print("[DEBUG] IBL: prefilter_cube_kernel not found")
            return nil
        }
        let pipeline: MTLComputePipelineState
        do {
            pipeline = try device.makeComputePipelineState(function: kernel)
        } catch {
            print("[DEBUG] IBL: prefilter pipeline failed — \(error)")
            return nil
        }

        // One dispatch per mip level — each writes to a view of that mip only.
        for mip in 0..<numMips {
            let mipSize = max(1, baseSize >> mip)
            let roughness = Float(mip) / Float(numMips - 1)

            // Texture view of just this mip's slice across all 6 faces.
            guard let mipView = texture.makeTextureView(
                pixelFormat: .rgba16Float,
                textureType: .typeCube,
                levels: mip..<(mip + 1),
                slices: 0..<6) else {
                print("[DEBUG] IBL: makeTextureView mip=\(mip) failed")
                return nil
            }
            mipView.label = "IBL_SpecMip\(mip)"

            guard let cmd = commandQueue.makeCommandBuffer(),
                  let enc = cmd.makeComputeCommandEncoder() else { return nil }
            enc.label = "IBL.specular mip=\(mip)"
            enc.setComputePipelineState(pipeline)
            enc.setTexture(mipView,    index: 0)
            enc.setTexture(envCubemap, index: 1)

            // PrefilterParams: float4 (roughness, 0, 0, 0).
            var params = SIMD4<Float>(roughness, 0, 0, 0)
            enc.setBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)

            let tg   = MTLSize(width: 8, height: 8, depth: 1)
            let grid = MTLSize(width: mipSize, height: mipSize, depth: 6)
            enc.dispatchThreads(grid, threadsPerThreadgroup: tg)
            enc.endEncoding()

            cmd.commit()
            cmd.waitUntilCompleted()
        }
        return texture
    }
}
