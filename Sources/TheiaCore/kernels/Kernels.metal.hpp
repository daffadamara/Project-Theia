#pragma once
//
// Metal Shading Language kernel sources, stored as C++ string constants and
// compiled at runtime via MTL::Device::newLibrary(source, ...).
//
// We compile at runtime (not the SwiftPM .metal -> .metallib path) because the
// offline `metal`/`metallib` compilers require full Xcode / the Metal toolchain,
// and this project targets a Command-Line-Tools-only environment.
//
namespace theia {
namespace kernels {

// M0 smoke test: write a constant value into every element of an output buffer.
inline constexpr const char* kFill = R"METAL(
#include <metal_stdlib>
using namespace metal;

kernel void fill(device float*    out   [[buffer(0)]],
                 constant float&  value [[buffer(1)]],
                 constant uint&   count [[buffer(2)]],
                 uint             gid   [[thread_position_in_grid]])
{
    if (gid >= count) { return; }
    out[gid] = value;
}
)METAL";

// fBm gradient (Perlin) noise generator. One thread per heightmap texel.
//
// Math references:
//   - Quintic fade f(t)=6t^5-15t^4+10t^3 (Perlin, "Improving Noise", 2002):
//     C2-continuous, removes 2nd-derivative artifacts of the cubic smoothstep.
//   - Value = bilinear interp (via fade weights) of corner gradient·distance
//     dot products.
//   - fBm: sum of `octaves`, frequency *= lacunarity, amplitude *= gain.
// Gradients are derived from an integer hash (no permutation table / texture
// lookup) so results are deterministic and GPU-parallel. Output is normalized
// to [0,1].
inline constexpr const char* kPerlinFbm = R"METAL(
#include <metal_stdlib>
using namespace metal;

struct PerlinParams {
    uint  width;
    uint  height;
    uint  octaves;
    uint  seed;
    float frequency;    // base cells across the unit domain
    float lacunarity;   // frequency multiplier per octave
    float gain;         // amplitude multiplier per octave (persistence)
    float _pad;
};

// Integer hash (Wang/xxHash-style mixing) -> uint.
static inline uint hash2(uint x, uint y, uint seed) {
    uint h = seed + 0x9E3779B9u;
    h ^= x * 0x85EBCA77u; h = (h ^ (h >> 15)) * 0xC2B2AE3Du;
    h ^= y * 0x27D4EB2Fu; h = (h ^ (h >> 13)) * 0x165667B1u;
    return h ^ (h >> 16);
}

// Unit-length gradient from a lattice point, via a hashed angle.
static inline float2 grad2(int2 i, uint seed) {
    uint h = hash2(uint(i.x), uint(i.y), seed);
    float ang = float(h) * (6.28318530718 / 4294967296.0);
    return float2(cos(ang), sin(ang));
}

static inline float perlin2(float2 p, uint seed) {
    int2 ip = int2(floor(p));
    float2 f = p - float2(ip);
    float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);  // quintic fade

    float n00 = dot(grad2(ip + int2(0, 0), seed), f - float2(0.0, 0.0));
    float n10 = dot(grad2(ip + int2(1, 0), seed), f - float2(1.0, 0.0));
    float n01 = dot(grad2(ip + int2(0, 1), seed), f - float2(0.0, 1.0));
    float n11 = dot(grad2(ip + int2(1, 1), seed), f - float2(1.0, 1.0));

    float nx0 = mix(n00, n10, u.x);
    float nx1 = mix(n01, n11, u.x);
    return mix(nx0, nx1, u.y);  // ~[-0.707, 0.707]
}

kernel void perlin_fbm(device float*           out [[buffer(0)]],
                       constant PerlinParams&  P   [[buffer(1)]],
                       uint2                   gid [[thread_position_in_grid]])
{
    if (gid.x >= P.width || gid.y >= P.height) { return; }

    // Sample in a normalized domain so the result is resolution-independent.
    float2 uv = float2(gid) / float2(P.width, P.height);

    float sum = 0.0, amp = 1.0, freq = P.frequency, norm = 0.0;
    for (uint o = 0; o < P.octaves; ++o) {
        sum  += amp * perlin2(uv * freq, P.seed + o * 1013u);
        norm += amp;
        amp  *= P.gain;
        freq *= P.lacunarity;
    }
    float n = (norm > 0.0) ? (sum / norm) : 0.0;   // ~[-0.707, 0.707]
    n *= 1.41421356;                               // -> ~[-1, 1]
    out[gid.y * P.width + gid.x] = clamp(0.5 * n + 0.5, 0.0, 1.0);  // -> [0,1]
}
)METAL";

// Elementwise affine remap: out = clamp(in * scale + bias, 0, 1).
inline constexpr const char* kScaleBias = R"METAL(
#include <metal_stdlib>
using namespace metal;

kernel void scalebias(device float*         out [[buffer(0)]],
                      device const float*   in  [[buffer(1)]],
                      constant float2&      sb  [[buffer(2)]],  // x=scale, y=bias
                      constant uint2&       dim [[buffer(3)]],
                      uint2                 gid [[thread_position_in_grid]])
{
    if (gid.x >= dim.x || gid.y >= dim.y) { return; }
    uint i = gid.y * dim.x + gid.x;
    out[i] = clamp(in[i] * sb.x + sb.y, 0.0, 1.0);
}
)METAL";

// Linear blend of two inputs: out = clamp(mix(a, b, t), 0, 1).
inline constexpr const char* kCombine = R"METAL(
#include <metal_stdlib>
using namespace metal;

kernel void combine(device float*         out [[buffer(0)]],
                    device const float*   a   [[buffer(1)]],
                    device const float*   b   [[buffer(2)]],
                    constant float&       t   [[buffer(3)]],
                    constant uint2&       dim [[buffer(4)]],
                    uint2                 gid [[thread_position_in_grid]])
{
    if (gid.x >= dim.x || gid.y >= dim.y) { return; }
    uint i = gid.y * dim.x + gid.x;
    out[i] = clamp(mix(a[i], b[i], t), 0.0, 1.0);
}
)METAL";

// Terrace: quantize heights into N bands with a shaped riser between them,
// producing stratified plateaus. sharpness >= 1 flattens band tops and steepens
// the risers.
inline constexpr const char* kTerrace = R"METAL(
#include <metal_stdlib>
using namespace metal;

kernel void terrace(device float*        out [[buffer(0)]],
                    device const float*  in  [[buffer(1)]],
                    constant float2&     ps  [[buffer(2)]],  // x=steps, y=sharpness
                    constant uint2&      dim [[buffer(3)]],
                    uint2                gid [[thread_position_in_grid]])
{
    if (gid.x >= dim.x || gid.y >= dim.y) { return; }
    uint i = gid.y * dim.x + gid.x;
    float steps = max(1.0, ps.x);
    float sharp = max(0.001, ps.y);
    float h = clamp(in[i], 0.0, 1.0);
    float s = h * steps;
    float f = floor(s);
    float r = s - f;                 // position within band [0,1)
    float shaped = pow(r, sharp);    // flat low, steep riser
    out[i] = clamp((f + shaped) / steps, 0.0, 1.0);
}
)METAL";

// Slope mask: gradient magnitude (in vertically-scaled space) mapped through a
// smoothstep band -> [0,1]. Useful to drive material/colour by steepness.
inline constexpr const char* kSlopeMask = R"METAL(
#include <metal_stdlib>
using namespace metal;

kernel void slopemask(device float*        out [[buffer(0)]],
                      device const float*  in  [[buffer(1)]],
                      constant float4&     pr  [[buffer(2)]],  // x=low, y=high, z=heightScale, w=cellSize
                      constant uint2&      dim [[buffer(3)]],
                      uint2                gid [[thread_position_in_grid]])
{
    uint W = dim.x, H = dim.y;
    if (gid.x >= W || gid.y >= H) { return; }
    uint x = gid.x, y = gid.y, i = y * W + x;

    float hL = in[(x > 0)     ? i - 1 : i];
    float hR = in[(x < W - 1) ? i + 1 : i];
    float hT = in[(y > 0)     ? i - W : i];
    float hB = in[(y < H - 1) ? i + W : i];
    float gx = 0.5 * (hR - hL) * pr.z / pr.w;
    float gy = 0.5 * (hB - hT) * pr.z / pr.w;
    float slope = sqrt(gx * gx + gy * gy);
    out[i] = smoothstep(pr.x, pr.y, slope);
}
)METAL";

} // namespace kernels
} // namespace theia
