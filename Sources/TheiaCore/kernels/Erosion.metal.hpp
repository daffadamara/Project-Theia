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
// Stability additions are documented in
// docs/research/hydraulic-erosion-stability-notes.md: a half-cell Courant cap,
// bounded exponential bed/sediment exchange, an input-relative curvature
// limiter, and conservative settling applied only to slopes newly steepened by
// the solver. These guards address wet/dry spikes without blurring the source.
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

    // Time-consistent numerical friction damps the explicit pipe oscillator.
    // A fixed multiplier would change meaning when dt changes.
    f *= exp(-8.0 * P.dt);
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
    float dmean = 0.5 * (d1 + d2);
    float2 v = float2(0.0);
    float dryDepth = max(1e-6, 0.25 * P.rain * P.dt);
    if (dmean > dryDepth) {
        v = float2(dWx, dWy) / (P.cellSize * max(dmean, dryDepth));
        // Fade velocity continuously at wet/dry fronts instead of switching it
        // abruptly at a hard depth threshold.
        v *= dmean / (dmean + dryDepth);
        float speed = length(v);
        // Keep the sediment backtrace within half a cell (CFL <= 0.5).
        float maxSpeed = min(3.0, 0.5 * P.cellSize / max(P.dt, 1e-5));
        if (speed > maxSpeed) v *= maxSpeed / speed;
    }
    vel[i] = v;
    water[i] = d2;
}

// Erode or deposit by comparing transport capacity to carried sediment.
kernel void hydro_erode(device const float* tIn   [[buffer(0)]],
                        device float*       tOut  [[buffer(1)]],
                        device const float* water [[buffer(2)]],
                        device const float2* vel  [[buffer(4)]],
                        device const float* sIn   [[buffer(5)]],
                        device float*       sOut  [[buffer(6)]],
                        device const float* original [[buffer(8)]],
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
    float invDiameter = 0.5 / P.cellSize;
    float gx = (hR - hL) * invDiameter;
    float gy = (hB - hT) * invDiameter;
    float grad = sqrt(gx * gx + gy * gy);
    float sinAlpha = max(P.minTilt, grad / sqrt(1.0 + grad * grad));

    float vmag = length(vel[i]);
    float wetReference = max(1e-4, 4.0 * P.rain * P.dt);
    float wetness = water[i] / (water[i] + wetReference);
    float C = P.sedimentCap * sinAlpha * vmag * wetness;

    float s = sIn[i];
    float b = tIn[i];

    // Preserve the source terrain's legitimate high-frequency relief while
    // limiting additional single-cell curvature created by the solver.
    float neighborMean = 0.25 * (hL + hR + hT + hB);
    float oC = original[i] * P.heightScale;
    float oL = original[(x > 0)     ? i - 1 : i] * P.heightScale;
    float oR = original[(x < W - 1) ? i + 1 : i] * P.heightScale;
    float oT = original[(y > 0)     ? i - W : i] * P.heightScale;
    float oB = original[(y < H - 1) ? i + W : i] * P.heightScale;
    float originalMean = 0.25 * (oL + oR + oT + oB);
    float originalCurvature = oC - originalMean;
    float originalRelief = max(max(abs(oC - oL), abs(oC - oR)),
                               max(abs(oC - oT), abs(oC - oB)));
    float curvatureBudget = 0.03 * P.cellSize + 0.20 * originalRelief;
    float minimumCurvature = min(0.0, originalCurvature) - curvatureBudget;
    float maximumCurvature = max(0.0, originalCurvature) + curvatureBudget;

    // One iteration may move at most a small normalized bed height. The local
    // limit grows with source relief, so smooth hills stay smooth while rough
    // source terrain is not flattened.
    float normalizedLimit = 0.00035 * P.heightScale;
    float localLimit = 0.02 * P.cellSize + 0.15 * originalRelief;
    float maxTransfer = max(0.0, min(normalizedLimit, localLimit));
    if (C > s) {
        float response = 1.0 - exp(-P.suspension * P.dt);
        float amt = min(maxTransfer, max(0.0, response * (C - s)));
        // A curvature floor may reduce erosion, but it must never turn an
        // erosion exchange into unpaired bed creation.
        float candidate = min(b,
                              max(b - amt, neighborMean + minimumCurvature));
        amt = max(0.0, b - candidate);
        tOut[i] = candidate;
        sOut[i] = s + amt;
    } else {
        float response = 1.0 - exp(-P.deposition * P.dt);
        float amt = min(maxTransfer,
                        min(s, max(0.0, response * (s - C))));
        // Symmetrically, a curvature ceiling may reduce deposition, but it
        // must never lower the bed without adding that amount to sediment.
        float candidate = max(b,
                              min(b + amt, neighborMean + maximumCurvature));
        amt = max(0.0, candidate - b);
        tOut[i] = candidate;
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

    float2 p = float2(gid) - vel[i] * (P.dt / P.cellSize);
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

// Conservative bank settling. Only slope added beyond the original terrain
// (plus a high 55-degree talus threshold) is eligible, so this removes solver
// needles without softening legitimate source ridges.
kernel void hydro_settle_flux(device const float* terrain [[buffer(0)]],
                              device float4*      tflux   [[buffer(3)]],
                              device const float* original [[buffer(8)]],
                              constant HydroParams& P     [[buffer(7)]],
                              uint2 gid [[thread_position_in_grid]]) {
    uint W = P.width, H = P.height;
    if (gid.x >= W || gid.y >= H) return;
    uint x = gid.x, y = gid.y, i = idx(x, y, W);
    float b = terrain[i];
    float o = original[i] * P.heightScale;
    constexpr float talus55 = 1.4281480067;
    float baseThreshold = talus55 * P.cellSize;
    float tolerance = 0.025 * P.cellSize;

    float4 excess = float4(0.0);
    if (x > 0) {
        float originalDrop = max(0.0, o - original[i - 1] * P.heightScale);
        excess.x = max(0.0, b - terrain[i - 1] -
                            max(baseThreshold, originalDrop + tolerance));
    }
    if (x < W - 1) {
        float originalDrop = max(0.0, o - original[i + 1] * P.heightScale);
        excess.y = max(0.0, b - terrain[i + 1] -
                            max(baseThreshold, originalDrop + tolerance));
    }
    if (y > 0) {
        float originalDrop = max(0.0, o - original[i - W] * P.heightScale);
        excess.z = max(0.0, b - terrain[i - W] -
                            max(baseThreshold, originalDrop + tolerance));
    }
    if (y < H - 1) {
        float originalDrop = max(0.0, o - original[i + W] * P.heightScale);
        excess.w = max(0.0, b - terrain[i + W] -
                            max(baseThreshold, originalDrop + tolerance));
    }

    float sum = excess.x + excess.y + excess.z + excess.w;
    float4 give = float4(0.0);
    if (sum > 0.0) {
        float largest = max(max(excess.x, excess.y),
                            max(excess.z, excess.w));
        float move = min(0.0005 * P.heightScale, 0.175 * largest);
        give = excess * (move / sum);
    }
    tflux[i] = give;
}

kernel void hydro_settle_apply(device const float* tIn  [[buffer(0)]],
                               device float*       tOut [[buffer(1)]],
                               device const float4* tflux [[buffer(3)]],
                               constant HydroParams& P   [[buffer(7)]],
                               uint2 gid [[thread_position_in_grid]]) {
    uint W = P.width, H = P.height;
    if (gid.x >= W || gid.y >= H) return;
    uint x = gid.x, y = gid.y, i = idx(x, y, W);
    float4 own = tflux[i];
    float outflow = own.x + own.y + own.z + own.w;
    float inflow = 0.0;
    if (x > 0)     inflow += tflux[i - 1].y;
    if (x < W - 1) inflow += tflux[i + 1].x;
    if (y > 0)     inflow += tflux[i - W].w;
    if (y < H - 1) inflow += tflux[i + W].z;
    tOut[i] = tIn[i] - outflow + inflow;
}

// Scale back out of simulation space.
kernel void hydro_finish(device const float* terrain [[buffer(0)]],
                         device float*       output  [[buffer(9)]],
                         constant HydroParams& P      [[buffer(7)]],
                         uint2 gid [[thread_position_in_grid]]) {
    uint W = P.width, H = P.height;
    if (gid.x >= W || gid.y >= H) return;
    uint i = idx(gid.x, gid.y, W);
    output[i] = clamp(terrain[i] / P.heightScale, 0.0, 1.0);
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
