#pragma once
//
// Erosion compute kernels (MSL source, runtime-compiled).
//
// Hydraulic erosion follows the virtual-pipes / shallow-water model of
// Mei, Decaudin & Hu, "Fast Hydraulic Erosion Simulation and Visualization on
// GPU" (Pacific Graphics 2007). Per-cell state: terrain height b, water depth d,
// suspended sediment s, outflow flux f=(L,R,T,B), velocity v=(x,y). Each
// timestep: add rain -> update pipe flux (scaled by K so a cell never drains
// more water than it holds) -> move water & derive velocity -> erode/deposit by
// comparing local transport capacity C = Kc*sin(alpha)*|v| to carried sediment
// -> advect sediment semi-Lagrangianly -> evaporate.
//
// The simulation runs in a vertically-scaled space (terrain *= heightScale) so
// that slopes are O(1) at our [0,1] height range and unit cell spacing; output
// is scaled back by 1/heightScale.
//
// Thermal erosion is a separate talus-angle relaxation: material on slopes
// steeper than the talus angle slides to lower neighbors.
//
namespace theia {
namespace kernels {

inline constexpr const char* kHydraulic = R"METAL(
#include <metal_stdlib>
using namespace metal;

struct HydroParams {
    uint  width;
    uint  height;
    float dt;
    float rain;
    float evaporation;
    float gravity;
    float pipeArea;
    float pipeLength;
    float cellSize;
    float sedimentCap;   // Kc
    float suspension;    // Ks (dissolving rate)
    float deposition;    // Kd
    float minTilt;       // lower clamp on sin(alpha) so transport occurs on gentle slopes
    float heightScale;   // vertical exaggeration for the simulation
};

static inline uint idx(uint x, uint y, uint w) { return y * w + x; }

// Pre-scale the input terrain into simulation space.
kernel void hydro_init(device const float* input   [[buffer(8)]],
                       device float*       terrain [[buffer(0)]],
                       constant HydroParams& P     [[buffer(7)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= P.width || gid.y >= P.height) return;
    uint i = idx(gid.x, gid.y, P.width);
    terrain[i] = input[i] * P.heightScale;
}

kernel void hydro_rain(device float* water        [[buffer(2)]],
                       constant HydroParams& P     [[buffer(7)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= P.width || gid.y >= P.height) return;
    water[idx(gid.x, gid.y, P.width)] += P.dt * P.rain;
}

// Update the 4 outflow pipes from pressure (total-height) differences, then
// scale by K so total outflow volume never exceeds the water present.
kernel void hydro_flux(device const float* terrain [[buffer(0)]],
                       device const float* water   [[buffer(2)]],
                       device float4*      flux    [[buffer(3)]],
                       constant HydroParams& P     [[buffer(7)]],
                       uint2 gid [[thread_position_in_grid]]) {
    uint W = P.width, H = P.height;
    if (gid.x >= W || gid.y >= H) return;
    uint x = gid.x, y = gid.y, i = idx(x, y, W);
    float h = terrain[i] + water[i];

    float4 f = flux[i];   // (L, R, T, B)
    float c = P.dt * P.gravity * P.pipeArea / P.pipeLength;

    float dL = (x > 0)     ? h - (terrain[i - 1] + water[i - 1]) : 0.0;
    float dR = (x < W - 1) ? h - (terrain[i + 1] + water[i + 1]) : 0.0;
    float dT = (y > 0)     ? h - (terrain[i - W] + water[i - W]) : 0.0;
    float dB = (y < H - 1) ? h - (terrain[i + W] + water[i + W]) : 0.0;

    f.x = max(0.0, f.x + c * dL);
    f.y = max(0.0, f.y + c * dR);
    f.z = max(0.0, f.z + c * dT);
    f.w = max(0.0, f.w + c * dB);

    // No flux across the domain boundary.
    if (x == 0)     f.x = 0.0;
    if (x == W - 1) f.y = 0.0;
    if (y == 0)     f.z = 0.0;
    if (y == H - 1) f.w = 0.0;

    float sum = f.x + f.y + f.z + f.w;
    if (sum > 0.0) {
        float avail = water[i] * P.cellSize * P.cellSize;
        float K = min(1.0, avail / (sum * P.dt));
        f *= K;
    }
    flux[i] = f;
}

// Apply net flux to water depth and derive the velocity field.
kernel void hydro_water(device float*        water [[buffer(2)]],
                        device const float4* flux  [[buffer(3)]],
                        device float2*       vel   [[buffer(4)]],
                        constant HydroParams& P    [[buffer(7)]],
                        uint2 gid [[thread_position_in_grid]]) {
    uint W = P.width, H = P.height;
    if (gid.x >= W || gid.y >= H) return;
    uint x = gid.x, y = gid.y, i = idx(x, y, W);

    float4 fo = flux[i];
    float inL = (x > 0)     ? flux[i - 1].y : 0.0;  // left neighbor's Right pipe
    float inR = (x < W - 1) ? flux[i + 1].x : 0.0;  // right neighbor's Left pipe
    float inT = (y > 0)     ? flux[i - W].w : 0.0;  // top neighbor's Bottom pipe
    float inB = (y < H - 1) ? flux[i + W].z : 0.0;  // bottom neighbor's Top pipe

    float outflow = fo.x + fo.y + fo.z + fo.w;
    float inflow  = inL + inR + inT + inB;

    float d1 = water[i];
    float d2 = max(0.0, d1 + P.dt * (inflow - outflow) / (P.cellSize * P.cellSize));

    float dWx = 0.5 * ((inL - fo.x) + (fo.y - inR));
    float dWy = 0.5 * ((inT - fo.z) + (fo.w - inB));
    float dmean = max(1e-4, 0.5 * (d1 + d2));
    vel[i] = float2(dWx / (P.cellSize * dmean), dWy / (P.cellSize * dmean));
    water[i] = d2;
}

// Erode or deposit by comparing transport capacity to carried sediment.
kernel void hydro_erode(device const float* tIn   [[buffer(0)]],
                        device float*       tOut  [[buffer(1)]],
                        device const float* water [[buffer(2)]],
                        device const float2* vel  [[buffer(4)]],
                        device const float* sIn   [[buffer(5)]],
                        device float*       sOut  [[buffer(6)]],
                        constant HydroParams& P   [[buffer(7)]],
                        uint2 gid [[thread_position_in_grid]]) {
    uint W = P.width, H = P.height;
    if (gid.x >= W || gid.y >= H) return;
    uint x = gid.x, y = gid.y, i = idx(x, y, W);

    // Local slope from terrain gradient (central differences, clamped at edges).
    float hL = tIn[(x > 0)     ? i - 1 : i];
    float hR = tIn[(x < W - 1) ? i + 1 : i];
    float hT = tIn[(y > 0)     ? i - W : i];
    float hB = tIn[(y < H - 1) ? i + W : i];
    float gx = 0.5 * (hR - hL);
    float gy = 0.5 * (hB - hT);
    float grad = sqrt(gx * gx + gy * gy);
    float sinAlpha = max(P.minTilt, grad / sqrt(1.0 + grad * grad));

    float vmag = length(vel[i]);
    float C = P.sedimentCap * sinAlpha * vmag;

    float s = sIn[i];
    float b = tIn[i];
    if (C > s) {
        float amt = P.dt * P.suspension * (C - s);
        tOut[i] = b - amt;
        sOut[i] = s + amt;
    } else {
        float amt = P.dt * P.deposition * (s - C);
        tOut[i] = b + amt;
        sOut[i] = s - amt;
    }
}

// Move suspended sediment with the flow (semi-Lagrangian backtrace + bilinear).
kernel void hydro_advect(device const float* sIn  [[buffer(5)]],
                         device float*       sOut [[buffer(6)]],
                         device const float2* vel [[buffer(4)]],
                         constant HydroParams& P  [[buffer(7)]],
                         uint2 gid [[thread_position_in_grid]]) {
    uint W = P.width, H = P.height;
    if (gid.x >= W || gid.y >= H) return;
    uint x = gid.x, y = gid.y, i = idx(x, y, W);

    float2 p = float2(gid) - vel[i] * P.dt;
    p.x = clamp(p.x, 0.0, float(W - 1));
    p.y = clamp(p.y, 0.0, float(H - 1));

    uint x0 = uint(floor(p.x)), y0 = uint(floor(p.y));
    uint x1 = min(x0 + 1, W - 1), y1 = min(y0 + 1, H - 1);
    float fx = p.x - float(x0), fy = p.y - float(y0);

    float s00 = sIn[idx(x0, y0, W)], s10 = sIn[idx(x1, y0, W)];
    float s01 = sIn[idx(x0, y1, W)], s11 = sIn[idx(x1, y1, W)];
    sOut[i] = mix(mix(s00, s10, fx), mix(s01, s11, fx), fy);
}

kernel void hydro_evap(device float* water     [[buffer(2)]],
                       constant HydroParams& P  [[buffer(7)]],
                       uint2 gid [[thread_position_in_grid]]) {
    uint W = P.width, H = P.height;
    if (gid.x >= W || gid.y >= H) return;
    uint i = idx(gid.x, gid.y, W);
    water[i] *= max(0.0, 1.0 - P.evaporation * P.dt);
}

// Scale back out of simulation space.
kernel void hydro_finish(device const float* terrain [[buffer(0)]],
                         device float*       output  [[buffer(9)]],
                         constant HydroParams& P      [[buffer(7)]],
                         uint2 gid [[thread_position_in_grid]]) {
    uint W = P.width, H = P.height;
    if (gid.x >= W || gid.y >= H) return;
    uint i = idx(gid.x, gid.y, W);
    output[i] = terrain[i] / P.heightScale;
}
)METAL";

inline constexpr const char* kThermal = R"METAL(
#include <metal_stdlib>
using namespace metal;

struct ThermalParams {
    uint  width;
    uint  height;
    float talusTan;     // tan(talus angle)
    float strength;     // fraction of excess material moved per step
    float cellSize;
    float heightScale;
};

static inline uint idx(uint x, uint y, uint w) { return y * w + x; }

kernel void thermal_init(device const float* input   [[buffer(8)]],
                         device float*       terrain [[buffer(0)]],
                         constant ThermalParams& P    [[buffer(7)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= P.width || gid.y >= P.height) return;
    uint i = idx(gid.x, gid.y, P.width);
    terrain[i] = input[i] * P.heightScale;
}

// Compute material to send to each lower neighbor whose slope exceeds talus.
kernel void thermal_flux(device const float* terrain [[buffer(0)]],
                         device float4*      tflux   [[buffer(3)]],
                         constant ThermalParams& P    [[buffer(7)]],
                         uint2 gid [[thread_position_in_grid]]) {
    uint W = P.width, H = P.height;
    if (gid.x >= W || gid.y >= H) return;
    uint x = gid.x, y = gid.y, i = idx(x, y, W);
    float b = terrain[i];
    float threshold = P.talusTan * P.cellSize;

    float dL = (x > 0)     ? b - terrain[i - 1] : 0.0;
    float dR = (x < W - 1) ? b - terrain[i + 1] : 0.0;
    float dT = (y > 0)     ? b - terrain[i - W] : 0.0;
    float dB = (y < H - 1) ? b - terrain[i + W] : 0.0;

    float eL = (dL > threshold) ? dL : 0.0;
    float eR = (dR > threshold) ? dR : 0.0;
    float eT = (dT > threshold) ? dT : 0.0;
    float eB = (dB > threshold) ? dB : 0.0;
    float esum = eL + eR + eT + eB;

    float4 give = float4(0.0);
    if (esum > 0.0) {
        float dmax = max(max(eL, eR), max(eT, eB));
        float move = P.strength * 0.5 * dmax;   // total volume to shed this step
        give = float4(eL, eR, eT, eB) * (move / esum);
    }
    tflux[i] = give;
}

// Apply: subtract own outflow, add inflow from neighbors aimed at this cell.
kernel void thermal_apply(device const float* tIn  [[buffer(0)]],
                          device float*       tOut [[buffer(1)]],
                          device const float4* tflux [[buffer(3)]],
                          constant ThermalParams& P   [[buffer(7)]],
                          uint2 gid [[thread_position_in_grid]]) {
    uint W = P.width, H = P.height;
    if (gid.x >= W || gid.y >= H) return;
    uint x = gid.x, y = gid.y, i = idx(x, y, W);

    float4 g = tflux[i];
    float outflow = g.x + g.y + g.z + g.w;

    float inL = (x > 0)     ? tflux[i - 1].y : 0.0;  // left neighbor sends Right
    float inR = (x < W - 1) ? tflux[i + 1].x : 0.0;
    float inT = (y > 0)     ? tflux[i - W].w : 0.0;
    float inB = (y < H - 1) ? tflux[i + W].z : 0.0;

    tOut[i] = tIn[i] - outflow + (inL + inR + inT + inB);
}

kernel void thermal_finish(device const float* terrain [[buffer(0)]],
                           device float*       output  [[buffer(9)]],
                           constant ThermalParams& P    [[buffer(7)]],
                           uint2 gid [[thread_position_in_grid]]) {
    uint W = P.width, H = P.height;
    if (gid.x >= W || gid.y >= H) return;
    uint i = idx(gid.x, gid.y, W);
    output[i] = terrain[i] / P.heightScale;
}
)METAL";

} // namespace kernels
} // namespace theia
