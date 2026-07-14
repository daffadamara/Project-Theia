#pragma once

// This Source Code Form is subject to the terms of the Mozilla Public License,
// v. 2.0. If a copy of the MPL was not distributed with this file, You can
// obtain one at https://mozilla.org/MPL/2.0/.
//
// Procedural gully erosion filter inspired by Rune Skovbo Johansen's
// "Fast and Gorgeous Erosion Filter" and Advanced Terrain Erosion Filter.
// This Metal implementation was written for Theia from the published
// technique and is kept under MPL-2.0 because it closely follows that work.
// References:
// https://blog.runevision.com/2026/03/fast-and-gorgeous-erosion-filter.html
// https://www.shadertoy.com/view/33cXW8
// https://www.shadertoy.com/view/wXcfWn

namespace theia::kernels {

inline constexpr const char* kErosionFilter = R"MSL(
#include <metal_stdlib>
using namespace metal;

constant float kPi = 3.14159265358979323846f;
constant float kTau = 6.28318530717958647692f;

struct ErosionFilterParams {
    uint width;
    uint height;
    uint seed;
    uint octaves;

    float scale;
    float strength;
    float lacunarity;
    float gain;

    float gullyWeight;
    float detail;
    float ridgeRounding;
    float creaseRounding;

    float onset;
    float assumedSlope;
    float slopeMix;
    float cellScale;

    float normalization;
    float heightOffset;
    float fadeCenter;
    float fadeRange;
};

float clamp01(float value) {
    return clamp(value, 0.0f, 1.0f);
}

float2 hash22(float2 p, uint seed) {
    // Keep the seed offset exactly representable in float. Very large octave
    // offsets collapse neighboring lattice coordinates and create speckling.
    const float s = float(seed & 65535u);
    p += float2(s * 0.013173f, s * 0.071117f);
    const float2 k = float2(0.3183099f, 0.3678794f);
    p = p * k + k.yx;
    return -1.0f + 2.0f * fract(16.0f * k *
        fract(p.x * p.y * (p.x + p.y)));
}

float2 safeNormalize(float2 v) {
    const float len = length(v);
    return len > 1.0e-10f ? v / len : float2(0.0f);
}

float inversePowerCurve(float value, float power) {
    return 1.0f - pow(1.0f - clamp01(value), max(0.05f, power));
}

float easeOut(float value) {
    const float v = 1.0f - clamp01(value);
    return 1.0f - v * v;
}

float smoothStart(float value, float smoothing) {
    if (smoothing <= 1.0e-6f) return max(0.0f, value);
    if (value >= smoothing) return value - 0.5f * smoothing;
    return 0.5f * value * value / smoothing;
}

// C1-continuous altitude fade. The reference method accepts a user-supplied
// signed fade target; Theia derives it from normalized height and removes the
// hard-knee discontinuities at the requested range boundaries.
float stableFadeTarget(float height, float center, float range) {
    const float halfMapped = 0.5f +
        0.5f * (height - center) / max(1.0e-4f, range);
    const float t = clamp01(halfMapped);
    const float hermite = t * t * (3.0f - 2.0f * t);
    return 2.0f * hermite - 1.0f;
}

// Compress a signed displacement into the remaining [0,1] headroom. This is
// first-order identity around zero but approaches either boundary asymptotically,
// avoiding new hard-clipped spike/hole plateaus.
float addBoundedDelta(float base, float delta) {
    if (delta >= 0.0f) {
        const float headroom = max(0.0f, 1.0f - base);
        return base + delta * headroom / max(1.0e-8f, headroom + delta);
    }
    const float magnitude = -delta;
    const float headroom = max(0.0f, base);
    return base - magnitude * headroom /
        max(1.0e-8f, headroom + magnitude);
}

// Returns normalized cosine/sine stripe phases and the derivative direction.
float4 phacelle(float2 p, float2 direction, float stripeFrequency,
                float phaseOffset, float normalization, uint seed) {
    const float2 sideDirection = direction.yx * float2(-1.0f, 1.0f) *
        stripeFrequency * kTau;
    const float phase = phaseOffset * kTau;
    const float2 integerPart = floor(p);
    const float2 fractionalPart = fract(p);

    float2 phaseVector = float2(0.0f);
    float weightSum = 0.0f;
    for (int oy = -1; oy <= 2; ++oy) {
        for (int ox = -1; ox <= 2; ++ox) {
            const float2 gridOffset = float2(float(ox), float(oy));
            const float2 gridPoint = integerPart + gridOffset;
            const float2 randomOffset = hash22(gridPoint, seed) * 0.5f;
            const float2 fromCell = fractionalPart - gridOffset - randomOffset;
            const float squaredDistance = dot(fromCell, fromCell);
            const float weight = max(0.0f, exp(-2.0f * squaredDistance) - 0.01111f);
            const float wave = dot(fromCell, sideDirection) + phase;
            phaseVector += float2(cos(wave), sin(wave)) * weight;
            weightSum += weight;
        }
    }

    const float2 interpolated = phaseVector / max(weightSum, 1.0e-8f);
    float magnitude = length(interpolated);
    magnitude = max(1.0f - clamp01(normalization), magnitude);
    return float4(interpolated / max(magnitude, 1.0e-8f), sideDirection);
}

// Bilinear height sample at a normalized-domain position (clamped edges).
float sampleHeightUV(device const float* input, float2 uv,
                     constant ErosionFilterParams& p) {
    const float fx = clamp(uv.x, 0.0f, 1.0f) * float(max(1u, p.width - 1u));
    const float fy = clamp(uv.y, 0.0f, 1.0f) * float(max(1u, p.height - 1u));
    const uint x0 = uint(fx);
    const uint y0 = uint(fy);
    const uint x1 = min(x0 + 1u, p.width - 1u);
    const uint y1 = min(y0 + 1u, p.height - 1u);
    const float tx = fx - float(x0);
    const float ty = fy - float(y0);
    const float a = clamp01(input[y0 * p.width + x0]);
    const float b = clamp01(input[y0 * p.width + x1]);
    const float c = clamp01(input[y1 * p.width + x0]);
    const float d = clamp01(input[y1 * p.width + x1]);
    return mix(mix(a, b, tx), mix(c, d, tx), ty);
}

kernel void erosion_filter(device float* output [[buffer(0)]],
                           device const float* input [[buffer(1)]],
                           constant ErosionFilterParams& p [[buffer(2)]],
                           device float* ridgeOutput [[buffer(3)]],
                           uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.width || gid.y >= p.height) return;

    const uint index = gid.y * p.width + gid.x;
    const float inputHeight = clamp01(input[index]);
    if (p.strength <= 1.0e-7f || p.octaves == 0u) {
        output[index] = inputHeight;
        ridgeOutput[index] = 0.5f;
        return;
    }

    const float2 uv = float2(
        float(gid.x) / float(max(1u, p.width - 1u)),
        float(gid.y) / float(max(1u, p.height - 1u)));

    // Estimate the input gradient at the gully-cell scale (quarter of a cell,
    // never below one texel). Per-texel derivatives on detail-bearing rasters
    // can rotate the stripe direction at every sample and fragment otherwise
    // coherent gullies.
    const float minStep = 1.0f / float(max(
        1u, min(p.width - 1u, p.height - 1u)));
    const float slopeStep = max(minStep, p.scale * p.cellScale * 0.25f);
    const float slopeX =
        (sampleHeightUV(input, uv + float2(slopeStep, 0.0f), p) -
         sampleHeightUV(input, uv - float2(slopeStep, 0.0f), p)) /
        (2.0f * slopeStep);
    const float slopeY =
        (sampleHeightUV(input, uv + float2(0.0f, slopeStep), p) -
         sampleHeightUV(input, uv - float2(0.0f, slopeStep), p)) /
        (2.0f * slopeStep);
    float fadeTarget = stableFadeTarget(
        inputHeight, p.fadeCenter, p.fadeRange);

    float3 heightAndSlope = float3(inputHeight, slopeX, slopeY);
    const float3 original = heightAndSlope;
    float octaveStrength = p.strength * p.scale;
    float frequency = 1.0f / max(1.0e-5f, p.scale * p.cellScale);
    const float slopeLength = max(length(heightAndSlope.yz), 1.0e-10f);
    float magnitude = 0.0f;
    float roundingMultiplier = 1.0f;

    const float inputRounding = mix(p.creaseRounding, p.ridgeRounding,
        clamp01(fadeTarget + 0.5f)) * 0.1f;
    float combinedMask = easeOut(smoothStart(
        slopeLength * p.onset, inputRounding * p.onset));
    float ridgeMapCombiMask = easeOut(slopeLength * 2.8f);
    float ridgeMapFadeTarget = fadeTarget;

    const float2 measuredSlope = heightAndSlope.yz;
    const float2 overriddenSlope = safeNormalize(measuredSlope) * p.assumedSlope;
    float2 gullySlope = mix(measuredSlope, overriddenSlope, clamp01(p.slopeMix));
    const float sampleSpan = float(min(
        max(1u, p.width - 1u), max(1u, p.height - 1u)));

    const uint octaveCount = min(p.octaves, 8u);
    for (uint octave = 0u; octave < octaveCount; ++octave) {
        // A directly tessellated height grid needs more margin than the
        // theoretical two-sample Nyquist bound. Fade an octave in from 2.5 to
        // 4 samples per stripe cycle and reject all higher octaves once zero.
        const float cyclesPerDomain = frequency * p.cellScale;
        const float samplesPerCycle = sampleSpan /
            max(1.0e-5f, cyclesPerDomain);
        const float bandWeight = smoothstep(2.5f, 4.0f, samplesPerCycle);
        if (bandWeight <= 1.0e-6f) break;
        const float effectiveStrength = octaveStrength * bandWeight;

        float4 phase = phacelle(uv * frequency, safeNormalize(gullySlope),
            p.cellScale, 0.25f, p.normalization,
            p.seed);
        phase.zw *= -frequency;
        const float sloping = abs(phase.y);

        gullySlope += sign(phase.y) * phase.zw *
            effectiveStrength * p.gullyWeight;

        const float3 gullies = float3(phase.x, phase.y * phase.zw);
        const float3 faded = mix(float3(fadeTarget, 0.0f, 0.0f),
                                 gullies * p.gullyWeight,
                                 combinedMask);
        heightAndSlope += faded * effectiveStrength;
        magnitude += effectiveStrength;
        fadeTarget = mix(fadeTarget, faded.x, bandWeight);

        const float octaveRounding = mix(p.creaseRounding, p.ridgeRounding,
            clamp01(phase.x + 0.5f)) * roundingMultiplier;
        const float newMask = easeOut(smoothStart(
            sloping * p.onset, octaveRounding * p.onset));
        const float nextCombinedMask =
            inversePowerCurve(combinedMask, p.detail) * newMask;
        combinedMask = mix(combinedMask, nextCombinedMask, bandWeight);

        // Parallel unrounded/unweighted fade chain from the Advanced Terrain
        // Erosion Filter. It produces analysis data, not connected hydrology.
        const float nextRidgeMapFadeTarget = mix(
            ridgeMapFadeTarget, gullies.x, ridgeMapCombiMask);
        ridgeMapFadeTarget = mix(
            ridgeMapFadeTarget, nextRidgeMapFadeTarget, bandWeight);
        const float newRidgeMask = easeOut(sloping * 1.5f);
        ridgeMapCombiMask = mix(
            ridgeMapCombiMask,
            ridgeMapCombiMask * newRidgeMask,
            bandWeight);

        octaveStrength *= p.gain;
        frequency *= p.lacunarity;
        roundingMultiplier *= p.lacunarity;
    }

    const float erosionDelta = heightAndSlope.x - original.x;
    const float offset = p.heightOffset * magnitude;
    output[index] = clamp01(addBoundedDelta(
        inputHeight, erosionDelta + offset));
    const float ridgeMap = ridgeMapFadeTarget * (1.0f - ridgeMapCombiMask);
    ridgeOutput[index] = clamp01(ridgeMap * 0.5f + 0.5f);
}
)MSL";

} // namespace theia::kernels
