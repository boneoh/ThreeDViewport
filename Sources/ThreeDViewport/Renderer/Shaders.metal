#include <metal_stdlib>
using namespace metal;

// ── Shared structs (must match ShaderTypes.swift exactly) ────────────────────

struct Uniforms {
    float4x4 modelMatrix;
    float4x4 viewProjectionMatrix;
    float4x4 normalMatrix;
};

// Light type constants stored in ShaderLight.position.w
#define LIGHT_AMBIENT     0
#define LIGHT_DIRECTIONAL 1
#define LIGHT_POINT       2
#define LIGHT_SPOT        3
#define LIGHT_LASER       4

struct ShaderLight {
    float4 position;   // xyz=world pos,  w=type
    float4 direction;  // xyz=direction,  w=unused
    float4 color;      // xyz=RGB×intens, w=intensity
    float4 params;     // x=cos(inner), y=cos(outer), z=range, w=unused
};

struct LightUniforms {
    float4      ambientColor;
    uint4       countAndPad;   // x = lightCount
    ShaderLight lights[4];
};

struct BackgroundUniforms {
    float4 colorTop;
    float4 colorBottom;
};

// ── Scene vertex / fragment ───────────────────────────────────────────────────

struct VertexOut {
    float4 position      [[position]];
    float3 worldNormal;
    float3 worldPosition;
};

vertex VertexOut vertex_main(
    uint                    vid       [[vertex_id]],
    constant packed_float3 *positions [[buffer(0)]],
    constant packed_float3 *normals   [[buffer(1)]],
    constant Uniforms      &uniforms  [[buffer(2)]]
) {
    VertexOut out;

    float3 pos  = float3(positions[vid]);
    float3 norm = float3(normals[vid]);

    float4 worldPos4   = uniforms.modelMatrix * float4(pos, 1.0);
    out.position       = uniforms.viewProjectionMatrix * worldPos4;
    out.worldPosition  = worldPos4.xyz;

    float3x3 normalMat = float3x3(
        uniforms.normalMatrix.columns[0].xyz,
        uniforms.normalMatrix.columns[1].xyz,
        uniforms.normalMatrix.columns[2].xyz
    );
    out.worldNormal = normalize(normalMat * norm);

    return out;
}

// ── Light evaluation helper ───────────────────────────────────────────────────

float3 evaluateLight(ShaderLight light, float3 worldPos, float3 normal) {
    int lightType = int(light.position.w);

    // Ambient: uniform contribution, no direction calculation
    if (lightType == LIGHT_AMBIENT) {
        return light.color.rgb;
    }

    float3 lightDir;
    float  attenuation = 1.0;

    if (lightType == LIGHT_DIRECTIONAL) {
        // Infinite parallel rays — direction is the ray direction, negate for NdotL
        lightDir = normalize(-light.direction.xyz);

    } else {
        // Positional light (point, spot, laser)
        float3 toLight = light.position.xyz - worldPos;
        float  dist    = length(toLight);
        float  range   = light.params.z;

        if (dist >= range) return float3(0.0);

        lightDir = normalize(toLight);

        // Smooth inverse-square falloff with range cutoff
        float normDist = dist / range;
        attenuation    = pow(max(0.0, 1.0 - normDist * normDist), 2.0);

        // Spot / Laser: cone attenuation
        if (lightType == LIGHT_SPOT || lightType == LIGHT_LASER) {
            // Angle between the light's aim direction and the light→surface vector
            float3 surfaceDir = normalize(worldPos - light.position.xyz);
            float  cosAngle   = dot(surfaceDir, normalize(light.direction.xyz));
            float  cosInner   = light.params.x;
            float  cosOuter   = light.params.y;

            if (cosAngle < cosOuter) return float3(0.0);

            float spotAtten;
            if (lightType == LIGHT_LASER) {
                // Hard-edge pencil beam — step at the inner cone
                spotAtten = cosAngle >= cosInner ? 1.0 : 0.0;
            } else {
                // Soft spot: smooth transition from outer to inner
                spotAtten = smoothstep(cosOuter, cosInner, cosAngle);
            }
            attenuation *= spotAtten;
        }
    }

    float NdotL = max(dot(normal, lightDir), 0.0);
    return light.color.rgb * NdotL * attenuation;
}

// ── Scene fragment shader ─────────────────────────────────────────────────────

fragment float4 fragment_main(
    VertexOut              in         [[stage_in]],
    constant Uniforms     &uniforms   [[buffer(2)]],
    constant LightUniforms &lightData [[buffer(3)]]
) {
    float3 normal   = normalize(in.worldNormal);
    float3 worldPos = in.worldPosition;

    // Start with global ambient
    float3 totalLight = lightData.ambientColor.rgb;

    // Accumulate each active light
    uint count = lightData.countAndPad.x;
    for (uint i = 0; i < count; i++) {
        totalLight += evaluateLight(lightData.lights[i], worldPos, normal);
    }

    // Neutral off-white base colour so lighting reads clearly
    float3 baseColor   = float3(0.82, 0.82, 0.82);
    float3 finalColor  = saturate(baseColor * totalLight);

    return float4(finalColor, 1.0);
}

// ── Background gradient ───────────────────────────────────────────────────────

struct BgVertOut {
    float4 position [[position]];
    float  y;          // 0 = bottom of screen, 1 = top
};

// Generates a full-screen quad via triangle strip (no vertex buffer needed).
vertex BgVertOut background_vertex(uint vid [[vertex_id]]) {
    // Clip-space corners for a triangle strip covering the whole NDC square
    const float2 pos[4] = {
        float2(-1.0, -1.0),   // bottom-left
        float2( 1.0, -1.0),   // bottom-right
        float2(-1.0,  1.0),   // top-left
        float2( 1.0,  1.0)    // top-right
    };
    float2 p = pos[vid];
    BgVertOut out;
    out.position = float4(p, 0.999, 1.0);   // near far-plane so geometry renders in front
    out.y        = p.y * 0.5 + 0.5;          // remap [-1,1] → [0,1]
    return out;
}

fragment float4 background_fragment(
    BgVertOut                  in [[stage_in]],
    constant BackgroundUniforms &bg [[buffer(0)]]
) {
    float3 color = mix(bg.colorBottom.rgb, bg.colorTop.rgb, in.y);
    return float4(color, 1.0);
}
