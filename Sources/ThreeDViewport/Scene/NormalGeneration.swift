import simd

// Free functions for CPU-side normal generation.
// Called by GLTFLoader at load time and by ViewportView when the user changes
// a model's normal mode in the inspector.

// Accumulates face normals for every vertex that shares a triangle, then
// normalises — produces smooth shading from indexed geometry.
func generateSmoothedNormals(positions: [Float], indices: [UInt32]) -> [Float] {
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

// Assigns each vertex the face normal of the last triangle that references it.
// This gives flat (faceted) shading without unindexing the mesh.
func generateFlatNormals(positions: [Float], indices: [UInt32]) -> [Float] {
    var normals  = [Float](repeating: 0, count: positions.count)

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
            normals[vi] = fn.x; normals[vi+1] = fn.y; normals[vi+2] = fn.z
        }
    }

    return normals
}
