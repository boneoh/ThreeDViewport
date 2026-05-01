#include <metal_stdlib>
using namespace metal;

// Must match ShaderTypes.swift exactly (240 bytes total).
struct Uniforms {
    float4x4 modelMatrix;
    float4x4 viewProjectionMatrix;
    float4x4 normalMatrix;
    float4   lightDirection;   // xyz = direction (world space), w unused
    float4   lightColor;       // xyz = RGB, w unused
    float4   ambientColor;     // xyz = RGB, w unused
};

struct VertexOut {
    float4 position      [[position]];
    float3 worldNormal;
    float3 worldPosition;
};

// Positions and normals are stored as tightly-packed float3 (12 bytes each).
// Use packed_float3 so Metal does not assume 16-byte element stride.
vertex VertexOut vertex_main(
    uint                    vid       [[vertex_id]],
    constant packed_float3 *positions [[buffer(0)]],
    constant packed_float3 *normals   [[buffer(1)]],
    constant Uniforms      &uniforms  [[buffer(2)]]
) {
    VertexOut out;

    float3 pos  = float3(positions[vid]);
    float3 norm = float3(normals[vid]);

    float4 worldPos    = uniforms.modelMatrix * float4(pos, 1.0);
    out.position       = uniforms.viewProjectionMatrix * worldPos;
    out.worldPosition  = worldPos.xyz;

    // Extract upper-left 3x3 of normalMatrix for transforming normals.
    float3x3 normalMat = float3x3(
        uniforms.normalMatrix.columns[0].xyz,
        uniforms.normalMatrix.columns[1].xyz,
        uniforms.normalMatrix.columns[2].xyz
    );
    out.worldNormal = normalize(normalMat * norm);

    return out;
}

fragment float4 fragment_main(
    VertexOut          in       [[stage_in]],
    constant Uniforms &uniforms [[buffer(2)]]
) {
    float3 normal   = normalize(in.worldNormal);
    float3 lightDir = normalize(-uniforms.lightDirection.xyz);

    float  NdotL    = max(dot(normal, lightDir), 0.0);
    float3 diffuse  = uniforms.lightColor.xyz * NdotL;
    float3 ambient  = uniforms.ambientColor.xyz;
    float3 color    = saturate(ambient + diffuse);

    return float4(color, 1.0);
}
