import simd

// Uniforms must exactly match the Metal struct in Shaders.metal.
// All vectors are padded to float4 to avoid Metal alignment surprises.
// Layout (bytes):
//   modelMatrix          64
//   viewProjectionMatrix 64
//   normalMatrix         64
//   lightDirection       16   (xyz used, w ignored)
//   lightColor           16   (xyz used, w ignored)
//   ambientColor         16   (xyz used, w ignored)
//   ─────────────────────────
//   Total               240

struct Uniforms {
    var modelMatrix: matrix_float4x4
    var viewProjectionMatrix: matrix_float4x4
    var normalMatrix: matrix_float4x4
    var lightDirection: SIMD4<Float>
    var lightColor: SIMD4<Float>
    var ambientColor: SIMD4<Float>
}
