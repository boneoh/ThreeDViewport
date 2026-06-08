import Foundation
import simd

/// Minimal binary-glTF (.glb) writer.  Emits a self-contained model from a flat
/// list of meshes — each a node (with a transform) carrying one primitive
/// (POSITION + optional NORMAL + indices) and a factor-only PBR material.  No
/// textures, skins, or animation: just baked geometry + materials, which is exactly
/// what "export a glued assembly as a reusable model" needs.
///
/// Layout: a single binary buffer (the GLB BIN chunk) holds every accessor's data,
/// 4-byte aligned; the JSON chunk describes accessors / bufferViews / meshes /
/// materials / nodes.  One root node parents every mesh node.
enum GLBExporter {

    struct Mesh {
        let name:      String
        let positions: [Float]            // tightly-packed xyz
        let normals:   [Float]?           // tightly-packed xyz (same vertex count) or nil
        let uvs:       [Float]?           // tightly-packed st (TEXCOORD_0) or nil
        let indices:   [UInt32]
        let transform: matrix_float4x4    // node matrix (model space)
        let baseColor: SIMD4<Float>       // rgba
        let metallic:  Float
        let roughness: Float
        let emissive:  SIMD3<Float>       // rgb
        // Retained source images per texture slot (nil = no texture).
        let baseColorTex:  TextureSource?
        let metalRoughTex: TextureSource?
        let normalTex:     TextureSource?
        let emissiveTex:   TextureSource?
    }

    /// Builds the `.glb` bytes, or nil if there's nothing to write.
    static func build(meshes: [Mesh], assetName: String) -> Data? {
        guard !meshes.isEmpty else { return nil }

        var bin           = Data()
        var bufferViews:   [[String: Any]] = []
        var accessors:     [[String: Any]] = []
        var meshesJSON:    [[String: Any]] = []
        var materialsJSON: [[String: Any]] = []
        var nodesJSON:     [[String: Any]] = []
        var childIndices:  [Int] = []
        var imagesJSON:    [[String: Any]] = []
        var texturesJSON:  [[String: Any]] = []
        var imageCache:    [Data: Int] = [:]   // image bytes → image index
        var textureCache:  [Data: Int] = [:]   // image bytes → texture index (shared sampler 0)

        func pad4() { while bin.count % 4 != 0 { bin.append(0) } }
        func addBufferView(_ data: Data, target: Int?) -> Int {
            pad4()
            var bv: [String: Any] = ["buffer": 0, "byteOffset": bin.count, "byteLength": data.count]
            if let target = target { bv["target"] = target }
            bufferViews.append(bv)
            bin.append(data)
            return bufferViews.count - 1
        }

        // Embeds a texture's image (deduped by bytes) and returns its texture index.
        func textureIndex(_ src: TextureSource?) -> Int? {
            guard let src = src else { return nil }
            if let t = textureCache[src.data] { return t }
            let imgIdx: Int
            if let cached = imageCache[src.data] {
                imgIdx = cached
            } else {
                let bv = addBufferView(src.data, target: nil)
                imagesJSON.append(["bufferView": bv, "mimeType": src.mimeType])
                imgIdx = imagesJSON.count - 1
                imageCache[src.data] = imgIdx
            }
            texturesJSON.append(["source": imgIdx, "sampler": 0])
            let texIdx = texturesJSON.count - 1
            textureCache[src.data] = texIdx
            return texIdx
        }

        for m in meshes {
            let vcount = m.positions.count / 3
            guard vcount > 0, !m.indices.isEmpty else { continue }

            // POSITION (requires min/max).
            let posBV = addBufferView(m.positions.withUnsafeBytes { Data($0) }, target: 34962)
            var mn = SIMD3<Float>(repeating:  .greatestFiniteMagnitude)
            var mx = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for v in 0..<vcount {
                let p = SIMD3<Float>(m.positions[v*3], m.positions[v*3+1], m.positions[v*3+2])
                mn = simd_min(mn, p); mx = simd_max(mx, p)
            }
            accessors.append(["bufferView": posBV, "componentType": 5126, "count": vcount,
                              "type": "VEC3",
                              "min": [Double(mn.x), Double(mn.y), Double(mn.z)],
                              "max": [Double(mx.x), Double(mx.y), Double(mx.z)]])
            var attributes: [String: Any] = ["POSITION": accessors.count - 1]

            // NORMAL (optional).
            if let normals = m.normals, normals.count == m.positions.count {
                let nBV = addBufferView(normals.withUnsafeBytes { Data($0) }, target: 34962)
                accessors.append(["bufferView": nBV, "componentType": 5126,
                                  "count": vcount, "type": "VEC3"])
                attributes["NORMAL"] = accessors.count - 1
            }

            // Texture references (embedded) + TEXCOORD_0 when any texture is present.
            let baseTexI  = textureIndex(m.baseColorTex)
            let mrTexI    = textureIndex(m.metalRoughTex)
            let normTexI  = textureIndex(m.normalTex)
            let emisTexI  = textureIndex(m.emissiveTex)
            let hasTexture = baseTexI != nil || mrTexI != nil || normTexI != nil || emisTexI != nil
            if hasTexture, let uvs = m.uvs, uvs.count == 2 * vcount {
                let uvBV = addBufferView(uvs.withUnsafeBytes { Data($0) }, target: 34962)
                accessors.append(["bufferView": uvBV, "componentType": 5126,
                                  "count": vcount, "type": "VEC2"])
                attributes["TEXCOORD_0"] = accessors.count - 1
            }

            // Indices (UNSIGNED_INT).
            let idxBV = addBufferView(m.indices.withUnsafeBytes { Data($0) }, target: 34963)
            accessors.append(["bufferView": idxBV, "componentType": 5125,
                              "count": m.indices.count, "type": "SCALAR"])
            let idxAcc = accessors.count - 1

            // Material (factors + any embedded textures).
            let alpha = Double(m.baseColor.w)
            var pbr: [String: Any] = [
                "baseColorFactor": [Double(m.baseColor.x), Double(m.baseColor.y),
                                    Double(m.baseColor.z), alpha],
                "metallicFactor":  Double(m.metallic),
                "roughnessFactor": Double(m.roughness)
            ]
            if let i = baseTexI { pbr["baseColorTexture"]         = ["index": i] }
            if let i = mrTexI   { pbr["metallicRoughnessTexture"] = ["index": i] }
            var material: [String: Any] = [
                "name": m.name,
                "pbrMetallicRoughness": pbr,
                "emissiveFactor": [Double(m.emissive.x), Double(m.emissive.y), Double(m.emissive.z)]
            ]
            if let i = normTexI { material["normalTexture"]   = ["index": i] }
            if let i = emisTexI { material["emissiveTexture"] = ["index": i] }
            if alpha < 0.999 { material["alphaMode"] = "BLEND" }
            materialsJSON.append(material)

            meshesJSON.append(["name": m.name, "primitives": [[
                "attributes": attributes, "indices": idxAcc,
                "material": materialsJSON.count - 1]]])

            nodesJSON.append(["name": m.name, "mesh": meshesJSON.count - 1,
                              "matrix": columnMajor(m.transform)])
            childIndices.append(nodesJSON.count - 1)
        }

        guard !childIndices.isEmpty else { return nil }

        nodesJSON.append(["name": assetName, "children": childIndices])
        let rootIndex = nodesJSON.count - 1

        var gltf: [String: Any] = [
            "asset":       ["version": "2.0", "generator": "ThreeDViewport"],
            "scene":       0,
            "scenes":      [["nodes": [rootIndex]]],
            "nodes":       nodesJSON,
            "meshes":      meshesJSON,
            "materials":   materialsJSON,
            "accessors":   accessors,
            "bufferViews": bufferViews,
            "buffers":     [["byteLength": bin.count]]
        ]
        if !imagesJSON.isEmpty {
            gltf["images"]   = imagesJSON
            gltf["textures"] = texturesJSON
            // One default sampler (REPEAT wrap, LINEAR min/mag) shared by all textures.
            gltf["samplers"] = [["wrapS": 10497, "wrapT": 10497, "magFilter": 9729, "minFilter": 9729]]
        }

        guard var json = try? JSONSerialization.data(withJSONObject: gltf, options: []) else { return nil }
        while json.count % 4 != 0 { json.append(0x20) }   // pad JSON chunk with spaces
        pad4()                                            // pad BIN chunk with zeros

        var glb = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { glb.append(contentsOf: $0) } }
        let total = 12 + 8 + json.count + 8 + bin.count
        u32(0x46546C67); u32(2); u32(UInt32(total))           // header: "glTF", version 2, length
        u32(UInt32(json.count)); u32(0x4E4F534A); glb.append(json)   // JSON chunk
        u32(UInt32(bin.count));  u32(0x004E4942); glb.append(bin)    // BIN chunk
        return glb
    }

    /// glTF `node.matrix` is column-major; simd columns are already columns.
    private static func columnMajor(_ m: matrix_float4x4) -> [Double] {
        [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap {
            [Double($0.x), Double($0.y), Double($0.z), Double($0.w)]
        }
    }
}
