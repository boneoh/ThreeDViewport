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
// Layout (struct alignment = 16, so the final size is padded up):
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
//   opacity             float    4   (multiplied into output alpha)
//   ───────────────────────────────  (+ 12 bytes pad → stride 80)
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
    var opacity:             Float          // multiplied into fragment alpha

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
        opacity             = 1.0
    }
}

// ── Background gradient uniforms (buffer index 0 in background pass) ────────
// Layout: two float4 = 32 bytes.
struct BackgroundUniforms {
    var colorTop:    SIMD4<Float>
    var colorBottom: SIMD4<Float>
}

// ── Bake face basis (buffer index 0 in cube_to_equirect_kernel) ───────────────
// Must match `struct FaceBasis` in IBLShaders.metal — 3 × float4 = 48 bytes.
struct FaceBasis {
    var forward: SIMD4<Float>   // xyz = look direction
    var right:   SIMD4<Float>   // xyz = camera right (image +x)
    var up:      SIMD4<Float>   // xyz = camera up    (image +y)
}

// ── Skybox / environment background uniforms (buffer index 0 in skybox pass) ──
// Must match `struct SkyboxUniforms` in Shaders.metal exactly.
// Layout: float4x4 (64) + float4 (16) + 4×4 = 96 bytes.
struct SkyboxUniforms {
    var inverseViewProjection: matrix_float4x4
    var cameraPos:             SIMD4<Float>   // xyz = world eye position
    var intensity:             Float          // brightness multiplier
    var horizon:               Float          // vertical shift of the sampled direction
    var useEquirect:           UInt32         // 1 = sample equirect, 0 = cube fallback
    var colorMode:             UInt32         // 0 grey, 1 color, 2 B+W matte
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

// ── Weather particle uniforms (vertex+fragment buffer 1 in the particle pass) ─
// Must match `struct ParticleFXUniforms` in ParticleFXShaders.metal exactly.
struct ParticleFXUniforms {
    var viewProjection: matrix_float4x4   // 64
    var cameraRight:    SIMD4<Float>      // 16  (xyz, w unused)
    var cameraUp:       SIMD4<Float>      // 16
    var emitterCenter:  SIMD4<Float>      // 16  (xyz centre)
    var emitterSize:    SIMD4<Float>      // 16  (xyz full extents)
    var color:          SIMD4<Float>      // 16  (rgb)
    var time:           Float
    var fallSpeed:      Float
    var particleSize:   Float
    var streak:         Float
    var sway:           Float
    var swayFreq:       Float
    var colorMode:      UInt32            // 2 = black+white matte → force white
    var mode:           UInt32            // 0 = falling weather, 1 = smoke (rise/grow/fade)
    var growth:         Float             // smoke: size growth over lifetime
    var lifetime:       Float             // smoke: particle lifetime (seconds)
    var baseAlpha:      Float             // per-particle base alpha
    var _pad:           Float = 0
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
    var colorMode:   UInt32 = 1          // 2 = black+white matte → force white
    var _pad0: UInt32 = 0; var _pad1: UInt32 = 0; var _pad2: UInt32 = 0
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

// ── Fog volume uniforms (fragment buffer 0 in the fog volume pass) ───────────
// Must match `struct FogVolumeUniforms` in FogVolumeShaders.metal exactly.
// Layout:
//   inverseViewProjection  float4x4   64
//   cameraPos              float4     16   (xyz)
//   boxMin                 float4     16   (xyz)
//   boxMax                 float4     16   (xyz)
//   color                  float4     16   (rgb)
//   density                float       4
//   variance               float       4
//   colorMode              uint        4   (0 greyscale, 1 color, 2 b+w matte)
//   steps                  uint        4   raymarch step count (quality)
//   ─────────────────────────────────────
//   Total                            144
struct FogVolumeUniforms {
    var inverseViewProjection: matrix_float4x4
    var cameraPos: SIMD4<Float>
    var boxMin:    SIMD4<Float>
    var boxMax:    SIMD4<Float>
    var color:     SIMD4<Float>
    var density:   Float
    var variance:  Float
    var colorMode: UInt32
    var steps:     UInt32
}
