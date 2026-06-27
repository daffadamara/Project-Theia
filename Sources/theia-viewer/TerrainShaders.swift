// Terrain render shaders (MSL), compiled at runtime via device.makeLibrary —
// the offline `metal` compiler isn't available with Command Line Tools alone.
//
// The mesh has no vertex buffer: each vertex derives its grid (x,z) from
// vertex_id, reads its height from a shared buffer, displaces Y, and computes
// the surface normal from neighbor heights for lighting.
let terrainShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 mvp;
    float4 lightDirection;
    float heightScale;
    uint  gridW;
    uint  gridH;
    uint  _pad;
};

struct VOut {
    float4 position [[position]];
    float3 normal;
    float  height;
};

vertex VOut terrain_vertex(uint vid [[vertex_id]],
                           const device float* heights [[buffer(0)]],
                           constant Uniforms& U [[buffer(1)]]) {
    uint gx = vid % U.gridW;
    uint gz = vid / U.gridW;
    float h = heights[gz * U.gridW + gx];

    float fx = (float(gx) / float(U.gridW - 1)) * 2.0 - 1.0;
    float fz = (float(gz) / float(U.gridH - 1)) * 2.0 - 1.0;
    float y = h * U.heightScale;

    uint gxl = gx > 0 ? gx - 1 : gx;
    uint gxr = gx < U.gridW - 1 ? gx + 1 : gx;
    uint gzd = gz > 0 ? gz - 1 : gz;
    uint gzu = gz < U.gridH - 1 ? gz + 1 : gz;
    float hl = heights[gz * U.gridW + gxl];
    float hr = heights[gz * U.gridW + gxr];
    float hd = heights[gzd * U.gridW + gx];
    float hu = heights[gzu * U.gridW + gx];
    float sx = 2.0 / float(U.gridW - 1);
    float sz = 2.0 / float(U.gridH - 1);
    float slopeX = (hr - hl) * U.heightScale / (2.0 * sx);
    float slopeZ = (hu - hd) * U.heightScale / (2.0 * sz);
    float3 N = normalize(float3(-slopeX, 1.0, -slopeZ));

    VOut o;
    o.position = U.mvp * float4(fx, y, fz, 1.0);
    o.normal = N;
    o.height = h;
    return o;
}

fragment float4 terrain_fragment(VOut in [[stage_in]],
                                 constant Uniforms& U [[buffer(1)]]) {
    float3 N = normalize(in.normal);
    float3 L = normalize(U.lightDirection.xyz);
    float diff = max(0.0, dot(N, L));
    float amb = 0.32;

    float h = in.height;
    float3 low = float3(0.24, 0.43, 0.22);   // lowland green
    float3 mid = float3(0.50, 0.39, 0.28);   // rock brown
    float3 hi  = float3(0.93, 0.94, 0.97);   // snow
    float3 col = mix(low, mid, smoothstep(0.20, 0.55, h));
    col = mix(col, hi, smoothstep(0.76, 0.94, h));

    // Steep faces trend toward bare rock.
    float slope = 1.0 - N.y;
    col = mix(col, float3(0.32, 0.31, 0.29), smoothstep(0.32, 0.72, slope));

    float3 outc = col * (amb + diff * 0.95);
    return float4(outc, 1.0);
}
"""
