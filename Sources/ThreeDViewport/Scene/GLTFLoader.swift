import Foundation
import Metal
import MetalKit
import CoreGraphics
import ImageIO
import simd
import GLTFKit2

// Loads a .glb file using GLTFKit2 and produces a SceneObject with Metal buffers.
// Phase 8: also loads UV coordinates, tangents, and PBR material data.
final class GLTFLoader {

    let device: MTLDevice

    init(device: MTLDevice) {
        self.device = device
        print("[DEBUG] GLTFLoader: initialized")
    }

    // Returns the first SceneObject found, or nil on failure.
    func load(url: URL) -> SceneObject? {
        print("[DEBUG] GLTFLoader: loading " + url.lastPathComponent)

        let asset: GLTFAsset
        do {
            asset = try GLTFAsset(url: url)
        } catch {
            print("[DEBUG] GLTFLoader: GLTFAsset threw — " + error.localizedDescription)
            return nil
        }

        let scene: GLTFScene?
        if let ds = asset.defaultScene {
            scene = ds
        } else {
            scene = asset.scenes.first
        }

        let rootNodes: [GLTFNode]
        if let s = scene {
            rootNodes = s.nodes
        } else {
            rootNodes = asset.nodes
        }

        if rootNodes.isEmpty {
            print("[DEBUG] GLTFLoader: rootNodes is empty")
            return nil
        }

        for node in rootNodes {
            if let obj = processNode(node, parentTransform: matrix_identity_float4x4) {
                return obj
            }
        }

        print("[DEBUG] GLTFLoader: no mesh found")
        return nil
    }

    // MARK: - Node Traversal

    private func processNode(_ node: GLTFNode,
                              parentTransform: matrix_float4x4) -> SceneObject? {
        let worldTransform = parentTransform * node.matrix

        if let mesh = node.mesh {
            let name = node.name ?? "unnamed"
            if !mesh.primitives.isEmpty,
               let obj = buildSceneObject(from: mesh, transform: worldTransform, name: name) {
                return obj
            }
        }

        for child in node.childNodes {
            if let obj = processNode(child, parentTransform: worldTransform) {
                return obj
            }
        }

        return nil
    }

    // MARK: - Mesh → SceneObject

    private func buildSceneObject(from mesh: GLTFMesh,
                                   transform: matrix_float4x4,
                                   name: String) -> SceneObject? {
        guard let primitive = mesh.primitives.first else { return nil }

        // ── Positions (required) ────────────────────────────────────────────
        guard let posAccessor = primitive.attribute(forName: "POSITION")?.accessor,
              let positions   = extractFloat3(from: posAccessor, label: "POSITION") else {
            print("[DEBUG] GLTFLoader: POSITION missing or failed")
            return nil
        }

        let vertexCount = positions.count / 3
        if vertexCount == 0 { return nil }

        // ── Normals ─────────────────────────────────────────────────────────
        let normals: [Float]
        if let acc = primitive.attribute(forName: "NORMAL")?.accessor,
           let raw = extractFloat3(from: acc, label: "NORMAL") {
            normals = raw
        } else {
            let seq = (0..<vertexCount).map { UInt32($0) }
            normals = generateFlatNormals(positions: positions, indices: seq)
            print("[DEBUG] GLTFLoader: generated flat normals")
        }

        // ── Indices ─────────────────────────────────────────────────────────
        let indices: [UInt32]
        if let acc = primitive.indices,
           let raw = extractIndices(from: acc) {
            indices = raw
        } else {
            indices = (0..<vertexCount).map { UInt32($0) }
        }
        if indices.isEmpty { return nil }

        // ── UV coordinates ──────────────────────────────────────────────────
        var hasUVs = false
        let uvs: [Float]
        if let acc = primitive.attribute(forName: "TEXCOORD_0")?.accessor,
           let raw = extractFloat2(from: acc, label: "TEXCOORD_0") {
            uvs   = raw
            hasUVs = true
            print("[DEBUG] GLTFLoader: UV count = " + String(raw.count / 2))
        } else {
            // Dummy zero UVs — required so buffer(4) is always valid
            uvs = [Float](repeating: 0, count: vertexCount * 2)
        }

        // ── Tangents ────────────────────────────────────────────────────────
        var hasTangents = false
        let tangents: [Float]
        if let acc = primitive.attribute(forName: "TANGENT")?.accessor,
           let raw = extractFloat4(from: acc, label: "TANGENT") {
            tangents   = raw
            hasTangents = true
            print("[DEBUG] GLTFLoader: tangent count = " + String(raw.count / 4))
        } else if hasUVs {
            // Generate tangents from positions + UVs
            tangents   = generateTangents(positions: positions,
                                          normals:   normals,
                                          uvs:       uvs,
                                          indices:   indices)
            hasTangents = true
            print("[DEBUG] GLTFLoader: generated tangents")
        } else {
            // Dummy tangents
            tangents = [Float](repeating: 0, count: vertexCount * 4)
        }

        // ── Bounding sphere ─────────────────────────────────────────────────
        let (boundCenter, boundRadius) = computeBoundingSphere(positions: positions)

        // ── Metal buffers ───────────────────────────────────────────────────
        let posBuffer  = makeBuffer(positions, label: "positions")
        let normBuffer = makeBuffer(normals,   label: "normals")
        let uvBuffer   = makeBuffer(uvs,       label: "uvs")
        let tangBuffer = makeBuffer(tangents,  label: "tangents")
        let idxBuffer  = makeBuffer(indices,   label: "indices")

        // ── Material ────────────────────────────────────────────────────────
        let material = loadMaterial(from: primitive.material,
                                     hasTangents: hasTangents)

        // ── Assemble ────────────────────────────────────────────────────────
        let obj = SceneObject(name: name)
        obj.transform      = transform
        obj.positionBuffer = posBuffer
        obj.normalBuffer   = normBuffer
        obj.uvBuffer       = uvBuffer
        obj.tangentBuffer  = tangBuffer
        obj.indexBuffer    = idxBuffer
        obj.indexCount     = indices.count
        obj.boundingCenter = boundCenter
        obj.boundingRadius = boundRadius
        obj.material       = material

        obj.validateBuffers()
        print("[DEBUG] GLTFLoader: '" + name + "' ready — verts="
            + String(vertexCount) + " idx=" + String(indices.count))
        return obj
    }

    // MARK: - Material Loading

    private func loadMaterial(from gltfMat: GLTFMaterial?,
                               hasTangents: Bool) -> PBRMaterial {
        var mat = PBRMaterial()
        guard let gm = gltfMat else {
            print("[DEBUG] GLTFLoader: no material — using defaults")
            return mat
        }

        // PBR metallic-roughness
        if let pbr = gm.metallicRoughness {
            mat.baseColorFactor = SIMD4<Float>(pbr.baseColorFactor.x,
                                               pbr.baseColorFactor.y,
                                               pbr.baseColorFactor.z,
                                               pbr.baseColorFactor.w)
            mat.metallicFactor  = pbr.metallicFactor
            mat.roughnessFactor = pbr.roughnessFactor

            if let texParams = pbr.baseColorTexture,
               let img       = texParams.texture.source {
                mat.baseColorTexture = loadTexture(from: img, sRGB: true)
                print("[DEBUG] GLTFLoader: baseColorTexture " + (mat.baseColorTexture != nil ? "OK" : "FAILED"))
            }

            if let texParams = pbr.metallicRoughnessTexture,
               let img       = texParams.texture.source {
                mat.metallicRoughnessTexture = loadTexture(from: img, sRGB: false)
                print("[DEBUG] GLTFLoader: mrTexture " + (mat.metallicRoughnessTexture != nil ? "OK" : "FAILED"))
            }
        }

        // Normal map (only useful when we have tangents)
        if hasTangents,
           let texParams = gm.normalTexture,
           let img       = texParams.texture.source {
            mat.normalTexture = loadTexture(from: img, sRGB: false)
            print("[DEBUG] GLTFLoader: normalTexture " + (mat.normalTexture != nil ? "OK" : "FAILED"))
        }

        // Emissive
        if let em = gm.emissive {
            mat.emissiveFactor = SIMD3<Float>(em.emissiveFactor.x,
                                              em.emissiveFactor.y,
                                              em.emissiveFactor.z)
            let strength = em.emissiveStrength > 0 ? em.emissiveStrength : 1.0
            mat.emissiveFactor *= strength

            if let texParams = em.emissiveTexture,
               let img       = texParams.texture.source {
                mat.emissiveTexture = loadTexture(from: img, sRGB: true)
                print("[DEBUG] GLTFLoader: emissiveTexture " + (mat.emissiveTexture != nil ? "OK" : "FAILED"))
            }
        }

        return mat
    }

    // MARK: - Texture Loading

    private func loadTexture(from image: GLTFImage, sRGB: Bool) -> MTLTexture? {
        // Embedded image (GLB) — read raw bytes from the buffer view
        if let bv = image.bufferView, let data = bv.buffer.data {
            let start  = bv.offset
            let length = bv.length
            guard length > 0 else {
                print("[DEBUG] GLTFLoader: texture bufferView.length is zero")
                return nil
            }
            let imageData = data.subdata(in: start..<(start + length))
            return decodeTexture(from: imageData, sRGB: sRGB)
        }

        // External URI image
        if let uri = image.uri, uri.isFileURL {
            if let imageData = try? Data(contentsOf: uri) {
                return decodeTexture(from: imageData, sRGB: sRGB)
            }
        }

        print("[DEBUG] GLTFLoader: no usable image source")
        return nil
    }

    private func decodeTexture(from data: Data, sRGB: Bool) -> MTLTexture? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            print("[DEBUG] GLTFLoader: CGImageSource decode failed")
            return nil
        }

        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [
            .generateMipmaps: NSNumber(value: true),
            .SRGB:            NSNumber(value: sRGB)
        ]

        do {
            return try loader.newTexture(cgImage: cgImage, options: options)
        } catch {
            print("[DEBUG] GLTFLoader: MTKTextureLoader failed — " + error.localizedDescription)
            return nil
        }
    }

    // MARK: - Data Extraction Helpers

    // Tightly-packed float3 array from a VEC3 accessor.
    private func extractFloat3(from accessor: GLTFAccessor,
                                label: String) -> [Float]? {
        guard let bv   = accessor.bufferView,
              let data = bv.buffer.data else {
            print("[DEBUG] GLTFLoader: " + label + " bufferView/data nil")
            return nil
        }

        let count       = accessor.count
        let elemBytes   = 3 * MemoryLayout<Float>.size
        let strideBytes = bv.stride > 0 ? bv.stride : elemBytes
        let baseOffset  = bv.offset + accessor.offset

        var result = [Float]()
        result.reserveCapacity(count * 3)

        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for i in 0..<count {
                let ptr = base
                    .advanced(by: baseOffset + i * strideBytes)
                    .assumingMemoryBound(to: Float.self)
                result.append(ptr[0])
                result.append(ptr[1])
                result.append(ptr[2])
            }
        }

        return result
    }

    // Tightly-packed float2 array from a VEC2 accessor.
    private func extractFloat2(from accessor: GLTFAccessor,
                                label: String) -> [Float]? {
        guard let bv   = accessor.bufferView,
              let data = bv.buffer.data else {
            print("[DEBUG] GLTFLoader: " + label + " bufferView/data nil")
            return nil
        }

        let count       = accessor.count
        let elemBytes   = 2 * MemoryLayout<Float>.size
        let strideBytes = bv.stride > 0 ? bv.stride : elemBytes
        let baseOffset  = bv.offset + accessor.offset

        var result = [Float]()
        result.reserveCapacity(count * 2)

        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for i in 0..<count {
                let ptr = base
                    .advanced(by: baseOffset + i * strideBytes)
                    .assumingMemoryBound(to: Float.self)
                result.append(ptr[0])
                result.append(ptr[1])
            }
        }

        return result
    }

    // Tightly-packed float4 array from a VEC4 accessor.
    private func extractFloat4(from accessor: GLTFAccessor,
                                label: String) -> [Float]? {
        guard let bv   = accessor.bufferView,
              let data = bv.buffer.data else {
            print("[DEBUG] GLTFLoader: " + label + " bufferView/data nil")
            return nil
        }

        let count       = accessor.count
        let elemBytes   = 4 * MemoryLayout<Float>.size
        let strideBytes = bv.stride > 0 ? bv.stride : elemBytes
        let baseOffset  = bv.offset + accessor.offset

        var result = [Float]()
        result.reserveCapacity(count * 4)

        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for i in 0..<count {
                let ptr = base
                    .advanced(by: baseOffset + i * strideBytes)
                    .assumingMemoryBound(to: Float.self)
                result.append(ptr[0])
                result.append(ptr[1])
                result.append(ptr[2])
                result.append(ptr[3])
            }
        }

        return result
    }

    // Extracts indices as [UInt32], handling UInt16 and UInt32 source formats.
    private func extractIndices(from accessor: GLTFAccessor) -> [UInt32]? {
        guard let bv   = accessor.bufferView,
              let data = bv.buffer.data else {
            print("[DEBUG] GLTFLoader: index bufferView/data nil")
            return nil
        }

        let count      = accessor.count
        let baseOffset = bv.offset + accessor.offset
        var result     = [UInt32]()
        result.reserveCapacity(count)

        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            switch accessor.componentType {
            case .unsignedShort:
                for i in 0..<count {
                    let ptr = base.advanced(by: baseOffset + i * 2)
                                  .assumingMemoryBound(to: UInt16.self)
                    result.append(UInt32(ptr.pointee))
                }
            case .unsignedInt:
                for i in 0..<count {
                    let ptr = base.advanced(by: baseOffset + i * 4)
                                  .assumingMemoryBound(to: UInt32.self)
                    result.append(ptr.pointee)
                }
            default:
                print("[DEBUG] GLTFLoader: unexpected index componentType")
            }
        }

        return result
    }

    // MARK: - Tangent Generation (Lengyel algorithm)

    // Generates per-vertex tangents + handedness (w) from positions, normals, UVs.
    // Returns a flat [Float] array: [tx, ty, tz, w, tx, ty, tz, w, ...]
    private func generateTangents(positions: [Float],
                                   normals:   [Float],
                                   uvs:       [Float],
                                   indices:   [UInt32]) -> [Float] {
        let vertexCount = positions.count / 3
        var tan1 = [SIMD3<Float>](repeating: .zero, count: vertexCount)
        var tan2 = [SIMD3<Float>](repeating: .zero, count: vertexCount)

        let triCount = indices.count / 3
        for t in 0..<triCount {
            let i0 = Int(indices[t * 3])
            let i1 = Int(indices[t * 3 + 1])
            let i2 = Int(indices[t * 3 + 2])

            let v0 = SIMD3<Float>(positions[i0*3], positions[i0*3+1], positions[i0*3+2])
            let v1 = SIMD3<Float>(positions[i1*3], positions[i1*3+1], positions[i1*3+2])
            let v2 = SIMD3<Float>(positions[i2*3], positions[i2*3+1], positions[i2*3+2])

            let uv0 = SIMD2<Float>(uvs[i0*2], uvs[i0*2+1])
            let uv1 = SIMD2<Float>(uvs[i1*2], uvs[i1*2+1])
            let uv2 = SIMD2<Float>(uvs[i2*2], uvs[i2*2+1])

            let edge1 = v1 - v0
            let edge2 = v2 - v0
            let duv1  = uv1 - uv0
            let duv2  = uv2 - uv0

            let denom = duv1.x * duv2.y - duv2.x * duv1.y
            guard abs(denom) > 1e-7 else { continue }
            let f = 1.0 / denom

            let tangent   = (edge1 * duv2.y - edge2 * duv1.y) * f
            let bitangent = (edge2 * duv1.x - edge1 * duv2.x) * f

            for idx in [i0, i1, i2] {
                tan1[idx] += tangent
                tan2[idx] += bitangent
            }
        }

        var result = [Float]()
        result.reserveCapacity(vertexCount * 4)

        for i in 0..<vertexCount {
            let n = SIMD3<Float>(normals[i*3], normals[i*3+1], normals[i*3+2])
            let t = tan1[i]
            let lenT = simd_length(t)

            let tOrtho: SIMD3<Float>
            if lenT > 1e-7 {
                tOrtho = simd_normalize(t - n * simd_dot(n, t))
            } else {
                // Degenerate — pick an arbitrary perpendicular
                let arb = abs(n.x) < 0.9
                    ? SIMD3<Float>(1, 0, 0)
                    : SIMD3<Float>(0, 1, 0)
                tOrtho = simd_normalize(simd_cross(n, arb))
            }

            let handedness: Float = simd_dot(simd_cross(n, t), tan2[i]) < 0 ? -1.0 : 1.0

            result.append(tOrtho.x)
            result.append(tOrtho.y)
            result.append(tOrtho.z)
            result.append(handedness)
        }

        return result
    }

    // MARK: - Flat Normal Generation

    private func generateFlatNormals(positions: [Float], indices: [UInt32]) -> [Float] {
        let vertexCount = positions.count / 3
        var normals     = [Float](repeating: 0, count: positions.count)

        let triCount = indices.count / 3
        for t in 0..<triCount {
            let i0 = Int(indices[t*3]) * 3
            let i1 = Int(indices[t*3+1]) * 3
            let i2 = Int(indices[t*3+2]) * 3

            let v0 = SIMD3<Float>(positions[i0], positions[i0+1], positions[i0+2])
            let v1 = SIMD3<Float>(positions[i1], positions[i1+1], positions[i1+2])
            let v2 = SIMD3<Float>(positions[i2], positions[i2+1], positions[i2+2])
            let fn = simd_normalize(simd_cross(v1 - v0, v2 - v0))

            for vi in [i0, i1, i2] {
                normals[vi]     += fn.x
                normals[vi + 1] += fn.y
                normals[vi + 2] += fn.z
            }
        }

        for i in 0..<vertexCount {
            let vi = i * 3
            let n  = SIMD3<Float>(normals[vi], normals[vi+1], normals[vi+2])
            let len = simd_length(n)
            if len > 1e-7 {
                normals[vi] = n.x / len; normals[vi+1] = n.y / len; normals[vi+2] = n.z / len
            } else {
                normals[vi] = 0; normals[vi+1] = 1; normals[vi+2] = 0
            }
        }

        return normals
    }

    // MARK: - Bounding Sphere

    private func computeBoundingSphere(positions: [Float]) -> (SIMD3<Float>, Float) {
        let vertexCount = positions.count / 3
        guard vertexCount > 0 else { return (SIMD3<Float>(0,0,0), 1.0) }

        var minV = SIMD3<Float>(repeating:  Float.infinity)
        var maxV = SIMD3<Float>(repeating: -Float.infinity)

        for i in 0..<vertexCount {
            let p = SIMD3<Float>(positions[i*3], positions[i*3+1], positions[i*3+2])
            minV = simd_min(minV, p)
            maxV = simd_max(maxV, p)
        }

        let center = (minV + maxV) * 0.5
        var maxDist: Float = 0
        for i in 0..<vertexCount {
            let p = SIMD3<Float>(positions[i*3], positions[i*3+1], positions[i*3+2])
            maxDist = max(maxDist, simd_length(p - center))
        }

        return (center, maxDist > 0 ? maxDist : 1.0)
    }

    // MARK: - Buffer creation helper

    private func makeBuffer<T>(_ array: [T], label: String) -> MTLBuffer? {
        guard !array.isEmpty else { return nil }
        let buf = device.makeBuffer(bytes: array,
                                    length: array.count * MemoryLayout<T>.stride,
                                    options: .storageModeShared)
        if buf == nil { print("[DEBUG] GLTFLoader: makeBuffer nil for " + label) }
        return buf
    }
}
