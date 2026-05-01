import Foundation
import Metal
import simd
import GLTFKit2

// Loads a .glb file using GLTFKit2 and produces a SceneObject with Metal buffers.
// Phase 1: loads the first mesh found in the scene graph.
// Phase 3: will return all mesh nodes.
final class GLTFLoader {

    let device: MTLDevice

    init(device: MTLDevice) {
        self.device = device
        print("[DEBUG] GLTFLoader: initialized")
    }

    // Returns the first SceneObject found, or nil on failure.
    func load(url: URL) -> SceneObject? {
        print("[DEBUG] GLTFLoader: loading file " + url.lastPathComponent)

        let asset: GLTFAsset
        do {
            asset = try GLTFAsset(url: url)
        } catch {
            print("[DEBUG] GLTFLoader: GLTFAsset init threw - " + error.localizedDescription)
            return nil
        }

        // Prefer the designated default scene; fall back to first scene.
        let scene: GLTFScene?
        if let ds = asset.defaultScene {
            scene = ds
            print("[DEBUG] GLTFLoader: using defaultScene")
        } else if let first = asset.scenes.first {
            scene = first
            print("[DEBUG] GLTFLoader: defaultScene is nil, using first scene")
        } else {
            scene = nil
            print("[DEBUG] GLTFLoader: asset has no scenes at all")
        }

        let rootNodes: [GLTFNode]
        if let s = scene {
            rootNodes = s.nodes
        } else {
            rootNodes = asset.nodes
            print("[DEBUG] GLTFLoader: falling back to asset.nodes, count = " + String(asset.nodes.count))
        }

        if rootNodes.isEmpty {
            print("[DEBUG] GLTFLoader: rootNodes array is empty — nothing to render")
            return nil
        }

        print("[DEBUG] GLTFLoader: root node count = " + String(rootNodes.count))

        for node in rootNodes {
            if let obj = processNode(node, parentTransform: matrix_identity_float4x4) {
                return obj
            }
        }

        print("[DEBUG] GLTFLoader: traversed all nodes, no mesh found")
        return nil
    }

    // MARK: - Node Traversal

    private func processNode(_ node: GLTFNode, parentTransform: matrix_float4x4) -> SceneObject? {
        // GLTFKit2 always computes node.matrix (from matrix or TRS, whichever the file uses)
        let worldTransform = parentTransform * node.matrix

        if let mesh = node.mesh {
            let nodeName = node.name ?? "unnamed"
            print("[DEBUG] GLTFLoader: node '" + nodeName + "' has mesh '" + (mesh.name ?? "unnamed") + "'")
            print("[DEBUG] GLTFLoader: primitive count = " + String(mesh.primitives.count))

            if mesh.primitives.isEmpty {
                print("[DEBUG] GLTFLoader: mesh has zero primitives — skipping node")
            } else if let obj = buildSceneObject(from: mesh, transform: worldTransform, name: nodeName) {
                return obj
            }
        }

        // GLTFKit2 uses childNodes, not children
        for child in node.childNodes {
            if let obj = processNode(child, parentTransform: worldTransform) {
                return obj
            }
        }

        return nil
    }

    // MARK: - Mesh -> SceneObject

    private func buildSceneObject(from mesh: GLTFMesh,
                                   transform: matrix_float4x4,
                                   name: String) -> SceneObject? {
        guard let primitive = mesh.primitives.first else {
            print("[DEBUG] GLTFLoader: buildSceneObject — primitives is empty")
            return nil
        }

        // ── Positions (required) ─────────────────────────────────────────────
        // GLTFPrimitive.attributes is NSArray<GLTFAttribute*>; use attributeForName: to look up by semantic.
        guard let posAccessor = primitive.attribute(forName: "POSITION")?.accessor else {
            print("[DEBUG] GLTFLoader: POSITION attribute missing from primitive")
            return nil
        }

        guard let positions = extractFloat3(from: posAccessor, label: "POSITION") else {
            print("[DEBUG] GLTFLoader: failed to extract POSITION data")
            return nil
        }

        let vertexCount = positions.count / 3
        print("[DEBUG] GLTFLoader: vertex count = " + String(vertexCount))

        if vertexCount == 0 {
            print("[DEBUG] GLTFLoader: vertex count is zero — aborting")
            return nil
        }

        // ── Normals (optional; generate flat normals if absent) ───────────────
        let normals: [Float]
        if let normAccessor = primitive.attribute(forName: "NORMAL")?.accessor,
           let extracted = extractFloat3(from: normAccessor, label: "NORMAL") {
            print("[DEBUG] GLTFLoader: normal count = " + String(extracted.count / 3))
            normals = extracted
        } else {
            print("[DEBUG] GLTFLoader: NORMAL attribute absent or failed — generating flat normals")
            let seqIndices = (0..<vertexCount).map { UInt32($0) }
            normals = generateFlatNormals(positions: positions, indices: seqIndices)
        }

        // ── Indices ───────────────────────────────────────────────────────────
        let indices: [UInt32]
        if let idxAccessor = primitive.indices {
            guard let extracted = extractIndices(from: idxAccessor) else {
                print("[DEBUG] GLTFLoader: failed to extract index data")
                return nil
            }
            indices = extracted
            print("[DEBUG] GLTFLoader: index count = " + String(indices.count))
        } else {
            // Non-indexed geometry — synthesise sequential indices
            indices = (0..<vertexCount).map { UInt32($0) }
            print("[DEBUG] GLTFLoader: no index accessor, generated " + String(indices.count) + " sequential indices")
        }

        if indices.isEmpty {
            print("[DEBUG] GLTFLoader: index array is empty — aborting")
            return nil
        }

        // ── Bounding sphere ───────────────────────────────────────────────────
        let (boundCenter, boundRadius) = computeBoundingSphere(positions: positions)

        // ── Metal buffers ─────────────────────────────────────────────────────
        let posBuffer = device.makeBuffer(
            bytes: positions,
            length: positions.count * MemoryLayout<Float>.size,
            options: .storageModeShared
        )
        if posBuffer == nil {
            print("[DEBUG] GLTFLoader: MTLDevice.makeBuffer for positions returned nil")
        }

        let normBuffer = device.makeBuffer(
            bytes: normals,
            length: normals.count * MemoryLayout<Float>.size,
            options: .storageModeShared
        )
        if normBuffer == nil {
            print("[DEBUG] GLTFLoader: MTLDevice.makeBuffer for normals returned nil")
        }

        let idxBuffer = device.makeBuffer(
            bytes: indices,
            length: indices.count * MemoryLayout<UInt32>.size,
            options: .storageModeShared
        )
        if idxBuffer == nil {
            print("[DEBUG] GLTFLoader: MTLDevice.makeBuffer for indices returned nil")
        }

        // ── Assemble SceneObject ──────────────────────────────────────────────
        let obj = SceneObject(name: name)
        obj.transform      = transform
        obj.positionBuffer = posBuffer
        obj.normalBuffer   = normBuffer
        obj.indexBuffer    = idxBuffer
        obj.indexCount     = indices.count
        obj.boundingCenter = boundCenter
        obj.boundingRadius = boundRadius

        obj.validateBuffers()
        print("[DEBUG] GLTFLoader: SceneObject '" + name + "' ready — indexCount=" + String(obj.indexCount))
        return obj
    }

    // MARK: - Data Extraction Helpers

    // Extracts a tightly-packed [x,y,z, x,y,z, ...] Float array from a vec3 accessor.
    // GLTFBufferView properties: .offset (not byteOffset), .stride (not byteStride)
    // GLTFAccessor property:    .offset (not byteOffset)
    private func extractFloat3(from accessor: GLTFAccessor, label: String) -> [Float]? {
        guard let bufferView = accessor.bufferView else {
            print("[DEBUG] GLTFLoader: " + label + " accessor.bufferView is nil")
            return nil
        }

        guard let data = bufferView.buffer.data else {
            print("[DEBUG] GLTFLoader: " + label + " bufferView.buffer.data is nil")
            return nil
        }

        let count = accessor.count
        if count == 0 {
            print("[DEBUG] GLTFLoader: " + label + " accessor.count is zero")
            return nil
        }

        let elementBytes = 3 * MemoryLayout<Float>.size   // 12 bytes per float3
        let strideBytes  = bufferView.stride > 0 ? bufferView.stride : elementBytes
        let baseOffset   = bufferView.offset + accessor.offset

        var result = [Float]()
        result.reserveCapacity(count * 3)

        data.withUnsafeBytes { rawPtr in
            guard let base = rawPtr.baseAddress else {
                print("[DEBUG] GLTFLoader: " + label + " rawPtr.baseAddress is nil")
                return
            }
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

    // Extracts indices as [UInt32], handling both UInt16 and UInt32 source formats.
    private func extractIndices(from accessor: GLTFAccessor) -> [UInt32]? {
        guard let bufferView = accessor.bufferView else {
            print("[DEBUG] GLTFLoader: index accessor.bufferView is nil")
            return nil
        }

        guard let data = bufferView.buffer.data else {
            print("[DEBUG] GLTFLoader: index bufferView.buffer.data is nil")
            return nil
        }

        let count = accessor.count
        if count == 0 {
            print("[DEBUG] GLTFLoader: index accessor.count is zero")
            return []
        }

        let baseOffset = bufferView.offset + accessor.offset
        var result = [UInt32]()
        result.reserveCapacity(count)

        data.withUnsafeBytes { rawPtr in
            guard let base = rawPtr.baseAddress else {
                print("[DEBUG] GLTFLoader: index rawPtr.baseAddress is nil")
                return
            }

            switch accessor.componentType {
            case .unsignedShort:
                for i in 0..<count {
                    let ptr = base
                        .advanced(by: baseOffset + i * 2)
                        .assumingMemoryBound(to: UInt16.self)
                    result.append(UInt32(ptr.pointee))
                }
            case .unsignedInt:
                for i in 0..<count {
                    let ptr = base
                        .advanced(by: baseOffset + i * 4)
                        .assumingMemoryBound(to: UInt32.self)
                    result.append(ptr.pointee)
                }
            default:
                print("[DEBUG] GLTFLoader: unexpected index componentType rawValue=" + String(accessor.componentType.rawValue))
            }
        }

        return result
    }

    // MARK: - Flat Normal Generation

    private func generateFlatNormals(positions: [Float], indices: [UInt32]) -> [Float] {
        let vertexCount = positions.count / 3
        var normals = [Float](repeating: 0, count: positions.count)
        let triCount = indices.count / 3

        for t in 0..<triCount {
            let i0 = Int(indices[t * 3])     * 3
            let i1 = Int(indices[t * 3 + 1]) * 3
            let i2 = Int(indices[t * 3 + 2]) * 3

            let v0 = SIMD3<Float>(positions[i0],   positions[i0+1], positions[i0+2])
            let v1 = SIMD3<Float>(positions[i1],   positions[i1+1], positions[i1+2])
            let v2 = SIMD3<Float>(positions[i2],   positions[i2+1], positions[i2+2])

            let faceNormal = simd_normalize(simd_cross(v1 - v0, v2 - v0))

            for vi in [i0, i1, i2] {
                normals[vi]     += faceNormal.x
                normals[vi + 1] += faceNormal.y
                normals[vi + 2] += faceNormal.z
            }
        }

        for i in 0..<vertexCount {
            let vi = i * 3
            let n  = SIMD3<Float>(normals[vi], normals[vi + 1], normals[vi + 2])
            let len = simd_length(n)
            if len > 0.0001 {
                normals[vi]     = n.x / len
                normals[vi + 1] = n.y / len
                normals[vi + 2] = n.z / len
            } else {
                normals[vi]     = 0
                normals[vi + 1] = 1
                normals[vi + 2] = 0
            }
        }

        print("[DEBUG] GLTFLoader: flat normals generated for " + String(vertexCount) + " vertices")
        return normals
    }

    // MARK: - Bounding Sphere

    private func computeBoundingSphere(positions: [Float]) -> (SIMD3<Float>, Float) {
        let vertexCount = positions.count / 3
        guard vertexCount > 0 else {
            print("[DEBUG] GLTFLoader: computeBoundingSphere — zero vertices, returning unit sphere")
            return (SIMD3<Float>(0, 0, 0), 1.0)
        }

        var minV = SIMD3<Float>(repeating:  Float.infinity)
        var maxV = SIMD3<Float>(repeating: -Float.infinity)

        for i in 0..<vertexCount {
            let x = positions[i * 3]
            let y = positions[i * 3 + 1]
            let z = positions[i * 3 + 2]
            minV = simd_min(minV, SIMD3<Float>(x, y, z))
            maxV = simd_max(maxV, SIMD3<Float>(x, y, z))
        }

        let center = (minV + maxV) * 0.5
        var maxDist: Float = 0
        for i in 0..<vertexCount {
            let p = SIMD3<Float>(positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2])
            maxDist = max(maxDist, simd_length(p - center))
        }

        let radius = maxDist > 0 ? maxDist : 1.0
        print("[DEBUG] GLTFLoader: bounding sphere radius=" + String(radius))
        return (center, radius)
    }
}
