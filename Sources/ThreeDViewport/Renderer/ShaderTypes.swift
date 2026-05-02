import simd

// ── Per-object transform uniforms (buffer index 2) ──────────────────────────
// Phase 8: cameraPosition added for PBR view-direction calculation.
// Layout:
//   modelMatrix          64
//   viewProjectionMatrix 64
//   normalMatrix         64
//   cameraPosition       16   (xyz = world pos, w = unused)
//   ─────────────────────────
//   Total               208

struct Uniforms {
    var modelMatrix:          matrix_float4x4
    var viewProjectionMatrix: matrix_float4x4
    var normalMatrix:         matrix_float4x4
    var cameraPosition:       SIMD4<Float>
}

// ── Per-light data ───────────────────────────────────────────────────────────
// Matches the Metal ShaderLight struct exactly (64 bytes, 16-byte aligned).
//   position:  xyz = world-space position; w = light type (see LightType.rawValue)
//   direction: xyz = normalised direction the light points; w = unused
//   color:     xyz = RGB × intensity (pre-multiplied); w = raw intensity
//   params:    x = cos(innerConeAngle), y = cos(outerConeAngle),
//              z = range (world units), w = unused
struct ShaderLight {
    var position:  SIMD4<Float>
    var direction: SIMD4<Float>
    var color:     SIMD4<Float>
    var params:    SIMD4<Float>

    init() {
        position  = SIMD4<Float>(0, 0, 0, 1)   // w=1 → directional
        direction = SIMD4<Float>(0, -1, 0, 0)
        color     = SIMD4<Float>(0, 0, 0, 0)
        params    = SIMD4<Float>(0.97, 0.94, 10, 0)
    }
}

// ── Light uniforms block (buffer index 3) ───────────────────────────────────
// Layout:
//   ambientColor   float4  16
//   countAndPad    uint4   16  (x = active light count, yzw = padding)
//   light0..3      64×4   256
//   ─────────────────────────
//   Total                 288
struct LightUniforms {
    var ambientColor: SIMD4<Float>
    var countAndPad:  SIMD4<UInt32>   // x = lightCount
    var light0: ShaderLight
    var light1: ShaderLight
    var light2: ShaderLight
    var light3: ShaderLight

    init() {
        ambientColor = SIMD4<Float>(0.05, 0.05, 0.08, 0)
        countAndPad  = SIMD4<UInt32>(0, 0, 0, 0)
        light0 = ShaderLight()
        light1 = ShaderLight()
        light2 = ShaderLight()
        light3 = ShaderLight()
    }

    mutating func setLight(_ light: ShaderLight, at index: Int) {
        switch index {
        case 0: light0 = light
        case 1: light1 = light
        case 2: light2 = light
        case 3: light3 = light
        default: break
        }
    }
}

// ── Material uniforms (buffer index 4 — fragment only) ──────────────────────
// Phase 8: PBR material factors + texture-presence flags + color mode.
// Layout:
//   baseColorFactor     float4  16
//   emissiveFactor      float4  16   (w = unused)
//   metallicFactor      float    4
//   roughnessFactor     float    4
//   hasBaseColorTex     uint     4
//   hasNormalTex        uint     4
//   hasMetallicRoughTex uint     4
//   hasEmissiveTex      uint     4
//   colorMode           uint     4   (0 = greyscale, 1 = color)
//   pad                 uint     4
//   ───────────────────────────────
//   Total                       64
struct MaterialUniforms {
    var baseColorFactor:     SIMD4<Float>
    var emissiveFactor:      SIMD4<Float>   // w unused
    var metallicFactor:      Float
    var roughnessFactor:     Float
    var hasBaseColorTex:     UInt32
    var hasNormalTex:        UInt32
    var hasMetallicRoughTex: UInt32
    var hasEmissiveTex:      UInt32
    var colorMode:           UInt32         // 0 = greyscale, 1 = color
    var pad:                 UInt32

    init() {
        baseColorFactor     = SIMD4<Float>(1, 1, 1, 1)
        emissiveFactor      = SIMD4<Float>(0, 0, 0, 0)
        metallicFactor      = 0.0
        roughnessFactor     = 0.5
        hasBaseColorTex     = 0
        hasNormalTex        = 0
        hasMetallicRoughTex = 0
        hasEmissiveTex      = 0
        colorMode           = 0
        pad                 = 0
    }
}

// ── Background gradient uniforms (buffer index 0 in background pass) ────────
// Layout: two float4 = 32 bytes.
struct BackgroundUniforms {
    var colorTop:    SIMD4<Float>
    var colorBottom: SIMD4<Float>
}
