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
//   colorMode           uint     4   (0 = greyscale, 1 = color, 2 = black + white)
//   useFlatNormals      uint     4   (0 = vertex normals, 1 = compute from derivatives)
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
    var colorMode:           UInt32         // 0 = greyscale, 1 = color, 2 = black + white
    var useFlatNormals:      UInt32         // 0 = vertex normals, 1 = derivatives

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
        useFlatNormals      = 0
    }
}

// ── Background gradient uniforms (buffer index 0 in background pass) ────────
// Layout: two float4 = 32 bytes.
struct BackgroundUniforms {
    var colorTop:    SIMD4<Float>
    var colorBottom: SIMD4<Float>
}

// ── Laser beam billboard uniforms (buffer index 0 in laser beam pass) ────────
// Must match `struct LaserBeamUniforms` in LaserBeamShaders.metal exactly.
// Layout:
//   viewProjectionMatrix  float4x4   64
//   startWorld            float4     16   xyz = beam origin (w = 1)
//   endWorld              float4     16   xyz = beam tip    (w = 1)
//   color                 float4     16   xyz = linear RGB  (w = unused)
//   screenSize            float2      8   drawable pixels
//   thickness             float       4   beam width in pixels
//   pad                   float       4
//   ─────────────────────────────────────
//   Total                            128
struct LaserBeamUniforms {
    var viewProjectionMatrix: matrix_float4x4
    var startWorld: SIMD4<Float>
    var endWorld:   SIMD4<Float>
    var color:      SIMD4<Float>
    var screenSize: SIMD2<Float>
    var thickness:  Float
    var pad:        Float
}

// ── Laser hit effect uniforms (buffer index 0 in laser hit pass) ──────────────
// Must match `struct LaserHitUniforms` in LaserBeamShaders.metal exactly.
// Layout:
//   viewProjectionMatrix  float4x4   64
//   hitPoint              float4     16   xyz = world pos, w = 1
//   color                 float4     16   rgb = laser colour, w = 1
//   screenSize            float2      8   drawable pixels
//   hitRadius             float       4   billboard radius in pixels
//   time                  float       4   wall-clock / anim seconds
//   ─────────────────────────────────────
//   Total                            112
struct LaserHitUniforms {
    var viewProjectionMatrix: matrix_float4x4
    var hitPoint:   SIMD4<Float>
    var color:      SIMD4<Float>
    var screenSize: SIMD2<Float>
    var hitRadius:  Float
    var time:       Float
}

// ── Fog uniforms (fragment buffer index 5 in the scene pass) ─────────────────
// Must match `struct FogUniforms` in Shaders.metal exactly.
// Layout (16-byte aligned):
//   color    float3  16   display-space RGB (float3 occupies 16 bytes in Metal)
//   density  float    4   exponential density
//   start    float    4   distance before fog begins
//   enabled  uint     4   0 = off, 1 = on
//   _pad     float    4   alignment padding to 32
//   ─────────────────────────────────────
//   Total               32
struct FogUniforms {
    var color:   SIMD3<Float>
    var density: Float
    var start:   Float
    var enabled: UInt32
    var _pad:    Float = 0
}

// ── Spark particle GPU data (per-element in the instanced spark buffer) ───────
// Must match `struct SparkParticleGPU` in LaserBeamShaders.metal exactly.
// Layout (16-byte aligned):
//   position  float4  16   xyz = world pos, w unused
//   color     float4  16   rgb = colour, w unused
//   size      float    4   world-unit billboard half-extent
//   alpha     float    4   0–1 fade
//   pad       float2   8   alignment padding
//   ─────────────────────────────────────
//   Total               48
struct SparkParticleGPU {
    var position: SIMD4<Float>
    var color:    SIMD4<Float>
    var size:     Float
    var alpha:    Float
    var pad:      SIMD2<Float>
}

// ── Spark billboard uniforms (buffer index 1 in spark pass) ──────────────────
// Must match `struct SparkUniforms` in LaserBeamShaders.metal exactly.
// Layout:
//   viewProjectionMatrix  float4x4   64
//   cameraRight           float4     16
//   cameraUp              float4     16
//   ─────────────────────────────────────
//   Total                             96
struct SparkUniforms {
    var viewProjectionMatrix: matrix_float4x4
    var cameraRight: SIMD4<Float>
    var cameraUp:    SIMD4<Float>
}

// ── Scene-mode widget uniforms (buffer index 1 in widget pass) ───────────────
// Must match `struct WidgetUniforms` in WidgetShaders.metal exactly.
// Layout:
//   viewProjectionMatrix  float4x4   64
//   color                 float4     16  (linear RGBA, unpremultiplied)
//   ─────────────────────────────────────
//   Total                             80
struct WidgetUniforms {
    var viewProjectionMatrix: matrix_float4x4
    var color: SIMD4<Float>
}
