import Metal
import simd

// Per-instance shading data for reflection hits.  MUST match the `RTInstanceData`
// struct in Shaders.metal byte-for-byte (128 bytes, 16-aligned).
struct RTInstanceData {
    var normalMatrix:    matrix_float4x4    // object-space normal → world
    var baseColor:       SIMD4<Float>
    var emissive:        SIMD4<Float>       // xyz = effective emissive, w unused
    var metallic:        Float
    var roughness:       Float
    var indexOffset:     UInt32             // into the shared index buffer
    var vertexOffset:    UInt32             // into the shared normal/UV buffers (vertices)
    var hasNormals:      UInt32
    var hasBaseColorTex: UInt32
    var hasUV:           UInt32
    var pad0:            UInt32 = 0
}

// ─────────────────────────────────────────────────────────────────────────────
// Ray-traced reflections — scene acceleration structure + per-hit shading data.
//
// Builds a BVH from each SceneObject's existing GPU position/index buffers, plus
// shared buffers the fragment shader reads at a reflection hit:
//   • allNormals / allUVs — every mesh's object-space normals + UVs concatenated
//   • allIndices          — every mesh's indices concatenated
//   • instanceData        — per-instance material factors + offsets + normal matrix
//   • textureArg          — bindless table of per-instance baseColorTextures
// Indexed by the hit's instance_id / primitive_id.  Sharp, single-bounce, opaque
// geometry only; reflections show real base color + texture.
// ─────────────────────────────────────────────────────────────────────────────
final class RTReflectionSpike {

    private let device: MTLDevice
    private let textureArgEncoder: MTLArgumentEncoder?   // for the bindless table (buffer 13)
    private let whiteFallback: MTLTexture?               // 1×1 white → sample = factor unchanged

    private var primCache: [ObjectIdentifier: (accel: MTLAccelerationStructure, tris: Int)] = [:]

    private var instanceDescBuffer: MTLBuffer?
    private var topScratch:         MTLBuffer?
    private var topAccel:           MTLAccelerationStructure?

    // Shared shading buffers (geometry rebuilt only when the object set/order changes).
    private(set) var allNormals:   MTLBuffer?
    private(set) var allUVs:       MTLBuffer?
    private(set) var allIndices:   MTLBuffer?
    private(set) var instanceData: MTLBuffer?
    private(set) var textureArg:   MTLBuffer?
    // Structures + textures referenced indirectly → must be made resident.
    private(set) var residentStructures: [MTLAccelerationStructure] = []
    private(set) var residentTextures:   [MTLTexture] = []

    // Static per-instance geometry, keyed by the current object set.
    private var geomSigIDs:    [ObjectIdentifier] = []
    private var geomSigCounts: [Int]              = []
    private var staticOffsets: [(vtx: UInt32, idx: UInt32, hasN: UInt32, hasUV: UInt32, hasTex: UInt32)] = []

    init(device: MTLDevice, rtFragmentFunction: MTLFunction?) {
        self.device            = device
        self.textureArgEncoder = rtFragmentFunction?.makeArgumentEncoder(bufferIndex: 13)

        // 1×1 opaque white so `sample() * baseColorFactor` leaves untextured objects
        // at their factor colour.
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                         width: 1, height: 1, mipmapped: false)
        d.usage = .shaderRead
        whiteFallback = device.makeTexture(descriptor: d)
        var px: [UInt8] = [255, 255, 255, 255]
        whiteFallback?.replace(region: MTLRegionMake2D(0, 0, 1, 1),
                               mipmapLevel: 0, withBytes: &px, bytesPerRow: 4)

        if MemoryLayout<RTInstanceData>.stride != 128 {
            print("[RT] WARNING: RTInstanceData stride \(MemoryLayout<RTInstanceData>.stride) != 128 — shader layout desync")
        }
    }

    /// Build/refresh the scene BVH + shading buffers for `objects` at their current
    /// world transforms.  Encodes onto `commandBuffer` — MUST be called before the
    /// frame's render command encoder.  Returns the top-level structure to bind.
    func build(objects: [SceneObject],
               groupTransforms: [Int: matrix_float4x4],
               commandBuffer: MTLCommandBuffer) -> MTLAccelerationStructure? {

        let objs = objects.filter { $0.positionBuffer != nil && $0.indexBuffer != nil && $0.indexCount > 0 }
        guard !objs.isEmpty else { return nil }

        rebuildGeometryIfNeeded(objs)

        guard let enc = commandBuffer.makeAccelerationStructureCommandEncoder() else { return nil }

        var prims:     [MTLAccelerationStructure] = []
        var instances: [MTLAccelerationStructureInstanceDescriptor] = []
        var idata:     [RTInstanceData] = []
        idata.reserveCapacity(objs.count)

        for (i, object) in objs.enumerated() {
            let pos = object.positionBuffer!
            let idx = object.indexBuffer!
            let key  = ObjectIdentifier(pos)
            let tris = object.indexCount / 3

            let prim: MTLAccelerationStructure
            if let cached = primCache[key], cached.tris == tris {
                prim = cached.accel
            } else {
                let geo = MTLAccelerationStructureTriangleGeometryDescriptor()
                geo.vertexBuffer       = pos
                geo.vertexBufferOffset = 0
                geo.vertexStride       = MemoryLayout<Float>.size * 3   // packed_float3
                geo.vertexFormat       = .float3
                geo.indexBuffer        = idx
                geo.indexBufferOffset  = 0
                geo.indexType          = .uint32
                geo.triangleCount      = tris

                let pdesc = MTLPrimitiveAccelerationStructureDescriptor()
                pdesc.geometryDescriptors = [geo]

                let sizes = device.accelerationStructureSizes(descriptor: pdesc)
                guard let accel = device.makeAccelerationStructure(size: sizes.accelerationStructureSize),
                      let scratch = device.makeBuffer(length: max(sizes.buildScratchBufferSize, 16),
                                                      options: .storageModePrivate) else { continue }
                enc.build(accelerationStructure: accel,
                          descriptor:            pdesc,
                          scratchBuffer:         scratch,
                          scratchBufferOffset:   0)
                primCache[key] = (accel, tris)
                prim = accel
            }

            let m: matrix_float4x4
            if let gid = object.groupID, let gt = groupTransforms[gid] {
                m = gt * object.transform
            } else {
                m = object.transform
            }

            var inst = MTLAccelerationStructureInstanceDescriptor()
            inst.accelerationStructureIndex      = UInt32(prims.count)
            inst.mask                            = 0xFF
            inst.options                         = .opaque
            inst.intersectionFunctionTableOffset = 0
            inst.transformationMatrix            = Self.pack4x3(m)
            instances.append(inst)
            prims.append(prim)

            let off  = staticOffsets[i]
            let mat  = object.material
            let emis = mat.emissiveFactor
                     + SIMD3<Float>(mat.baseColorFactor.x, mat.baseColorFactor.y, mat.baseColorFactor.z)
                       * mat.emissiveStrength
            idata.append(RTInstanceData(
                normalMatrix:    simd_transpose(simd_inverse(m)),
                baseColor:       mat.baseColorFactor,
                emissive:        SIMD4<Float>(emis.x, emis.y, emis.z, 0),
                metallic:        mat.metallicFactor,
                roughness:       mat.roughnessFactor,
                indexOffset:     off.idx,
                vertexOffset:    off.vtx,
                hasNormals:      off.hasN,
                hasBaseColorTex: off.hasTex,
                hasUV:           off.hasUV))
        }

        guard !prims.isEmpty else { enc.endEncoding(); return nil }

        upload(&instances, into: &instanceDescBuffer,
               stride: MemoryLayout<MTLAccelerationStructureInstanceDescriptor>.stride)
        upload(&idata, into: &instanceData,
               stride: MemoryLayout<RTInstanceData>.stride)
        guard let ibuf = instanceDescBuffer else { enc.endEncoding(); return nil }

        let tdesc = MTLInstanceAccelerationStructureDescriptor()
        tdesc.instancedAccelerationStructures = prims
        tdesc.instanceCount                   = instances.count
        tdesc.instanceDescriptorBuffer        = ibuf

        let tsizes = device.accelerationStructureSizes(descriptor: tdesc)
        if topAccel == nil {
            topAccel = device.makeAccelerationStructure(size: tsizes.accelerationStructureSize)
        }
        if (topScratch?.length ?? 0) < tsizes.buildScratchBufferSize {
            topScratch = device.makeBuffer(length: max(tsizes.buildScratchBufferSize, 16),
                                           options: .storageModePrivate)
        }
        guard let top = topAccel, let scratch = topScratch else { enc.endEncoding(); return nil }
        enc.build(accelerationStructure: top,
                  descriptor:            tdesc,
                  scratchBuffer:         scratch,
                  scratchBufferOffset:   0)

        enc.endEncoding()

        var seen = Set<ObjectIdentifier>()
        residentStructures = prims.filter { seen.insert(ObjectIdentifier($0)).inserted }
        return top
    }

    /// Make the referenced primitive structures + reflected textures resident.
    func useResources(on encoder: MTLRenderCommandEncoder) {
        for s in residentStructures { encoder.useResource(s, usage: .read, stages: .fragment) }
        for t in residentTextures   { encoder.useResource(t, usage: .read, stages: .fragment) }
    }

    // MARK: - Private

    /// Concatenate every mesh's object-space normals + UVs + indices, build the
    /// bindless texture table, and record per-instance offsets.  Rebuilt only when
    /// the object set / order / triangle counts change.
    private func rebuildGeometryIfNeeded(_ objs: [SceneObject]) {
        let ids    = objs.map { ObjectIdentifier($0.positionBuffer!) }
        let counts = objs.map { $0.indexCount }
        if ids == geomSigIDs && counts == geomSigCounts { return }

        var normalsAccum: [Float]  = []
        var uvAccum:      [Float]  = []
        var indicesAccum: [UInt32] = []
        var offsets: [(vtx: UInt32, idx: UInt32, hasN: UInt32, hasUV: UInt32, hasTex: UInt32)] = []
        var textures: [MTLTexture] = []
        offsets.reserveCapacity(objs.count)

        for object in objs {
            let vtxCount = object.cpuPositions.count / 3
            let vtxOff   = UInt32(normalsAccum.count / 3)
            let idxOff   = UInt32(indicesAccum.count)

            let hasN: UInt32
            if object.originalNormals.count == vtxCount * 3 {
                normalsAccum.append(contentsOf: object.originalNormals)
                hasN = 1
            } else {
                normalsAccum.append(contentsOf: repeatElement(0, count: vtxCount * 3))
                hasN = 0
            }

            let hasUV: UInt32
            if object.cpuUVs.count == vtxCount * 2 {
                uvAccum.append(contentsOf: object.cpuUVs)
                hasUV = 1
            } else {
                uvAccum.append(contentsOf: repeatElement(0, count: vtxCount * 2))
                hasUV = 0
            }

            indicesAccum.append(contentsOf: object.cpuIndices)

            let tex = object.material.baseColorTexture
            textures.append(tex ?? whiteFallback!)
            offsets.append((vtxOff, idxOff, hasN, hasUV, tex != nil ? 1 : 0))
        }

        allNormals = normalsAccum.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }
        allUVs = uvAccum.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }
        allIndices = indicesAccum.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }
        buildTextureTable(textures)

        staticOffsets    = offsets
        residentTextures = textures
        geomSigIDs       = ids
        geomSigCounts    = counts
    }

    /// Encode the per-instance baseColorTextures into one bindless argument buffer.
    private func buildTextureTable(_ textures: [MTLTexture]) {
        guard let argEnc = textureArgEncoder, !textures.isEmpty else { textureArg = nil; return }
        let stride = argEnc.encodedLength
        let needed = stride * textures.count
        if (textureArg?.length ?? 0) < needed {
            textureArg = device.makeBuffer(length: needed, options: .storageModeShared)
        }
        guard let buf = textureArg else { return }
        for (i, tex) in textures.enumerated() {
            argEnc.setArgumentBuffer(buf, offset: i * stride)
            argEnc.setTexture(tex, index: 0)
        }
    }

    /// Copy a POD array into a shared MTLBuffer, growing it if needed.
    private func upload<T>(_ array: inout [T], into buffer: inout MTLBuffer?, stride: Int) {
        let needed = stride * array.count
        if (buffer?.length ?? 0) < needed {
            buffer = device.makeBuffer(length: needed, options: .storageModeShared)
        }
        guard let b = buffer else { return }
        array.withUnsafeBytes { raw in
            b.contents().copyMemory(from: raw.baseAddress!, byteCount: needed)
        }
    }

    /// simd column-major 4×4 → Metal packed 4×3 (three basis columns + translation).
    private static func pack4x3(_ m: matrix_float4x4) -> MTLPackedFloat4x3 {
        var p = MTLPackedFloat4x3()
        p.columns.0 = MTLPackedFloat3Make(m.columns.0.x, m.columns.0.y, m.columns.0.z)
        p.columns.1 = MTLPackedFloat3Make(m.columns.1.x, m.columns.1.y, m.columns.1.z)
        p.columns.2 = MTLPackedFloat3Make(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        p.columns.3 = MTLPackedFloat3Make(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        return p
    }
}
