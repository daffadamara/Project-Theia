#include "nodes/ErosionFilterNode.hpp"

#include <Metal/Metal.hpp>

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>

#include "GPUContext.hpp"
#include "Heightfield.hpp"
#include "kernels/ErosionFilter.metal.hpp"

namespace theia {
namespace {

// Must match ErosionFilterParams in kernels::kErosionFilter exactly.
struct ErosionFilterParamsGPU {
    std::uint32_t width;
    std::uint32_t height;
    std::uint32_t seed;
    std::uint32_t octaves;

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

float finiteParam(const ParamSet& params, const char* key, double fallback,
                  float minimum, float maximum) {
    const double raw = params.get(key, fallback);
    const float value = std::isfinite(raw) ? static_cast<float>(raw)
                                           : static_cast<float>(fallback);
    return std::clamp(value, minimum, maximum);
}

} // namespace

bool ErosionFilterNode::evaluate(GPUContext& ctx,
                                 const std::vector<const Heightfield*>& inputs,
                                 Heightfield& out, std::string& error) {
    Heightfield ridge(ctx, out.width(), out.height());
    if (!ridge.valid()) {
        error = "erosionfilter: failed to allocate ridge output";
        return false;
    }
    return evaluatePair(ctx, inputs, out, ridge, error);
}

bool ErosionFilterNode::evaluateOutputs(
    GPUContext& ctx, const std::vector<const Heightfield*>& inputs,
    const std::vector<Heightfield*>& outputs, std::string& error) {
    if (outputs.size() != 2 || !outputs[0] || !outputs[1]) {
        error = "erosionfilter '" + id() + "' requires height and ridge outputs";
        return false;
    }
    return evaluatePair(ctx, inputs, *outputs[0], *outputs[1], error);
}

bool ErosionFilterNode::evaluatePair(
    GPUContext& ctx, const std::vector<const Heightfield*>& inputs,
    Heightfield& out, Heightfield& ridge, std::string& error) {
    if (inputs.size() != 1 || !inputs[0]) {
        error = "erosionfilter '" + id() + "' requires 1 input";
        return false;
    }
    const Heightfield* input = inputs[0];
    if (input->width() != out.width() || input->height() != out.height()) {
        error = "erosionfilter: input size differs from output";
        return false;
    }
    if (ridge.width() != out.width() || ridge.height() != out.height()) {
        error = "erosionfilter: ridge size differs from height output";
        return false;
    }

    ErosionFilterParamsGPU p{};
    p.width = out.width();
    p.height = out.height();
    const double seedValue = params.get("seed", 1337);
    const double octaveValue = params.get("octaves", 5);
    p.seed = static_cast<std::uint32_t>(std::clamp(
        std::isfinite(seedValue) ? seedValue : 1337.0, 0.0, 4294967295.0));
    p.octaves = static_cast<std::uint32_t>(std::clamp(
        std::isfinite(octaveValue) ? octaveValue : 5.0, 0.0, 8.0));
    p.scale = finiteParam(params, "scale", 0.05, 0.005f, 0.06f);
    p.strength = finiteParam(params, "strength", 0.22, 0.0f, 1.0f);
    p.lacunarity = finiteParam(params, "lacunarity", 2.0, 1.0f, 4.0f);
    p.gain = finiteParam(params, "gain", 0.50, 0.0f, 1.0f);
    p.gullyWeight = finiteParam(params, "gullyWeight", 0.35, 0.0f, 0.65f);
    p.detail = finiteParam(params, "detail", 1.50, 0.05f, 6.0f);
    p.ridgeRounding = finiteParam(params, "ridgeRounding", 0.18, 0.0f, 1.0f);
    p.creaseRounding = finiteParam(params, "creaseRounding", 0.10, 0.0f, 1.0f);
    p.onset = finiteParam(params, "onset", 1.25, 0.05f, 8.0f);
    p.assumedSlope = finiteParam(params, "assumedSlope", 0.70, 0.0f, 8.0f);
    p.slopeMix = finiteParam(params, "slopeMix", 1.00, 0.0f, 1.0f);
    p.cellScale = finiteParam(params, "cellScale", 0.70, 0.10f, 4.0f);
    p.normalization = finiteParam(params, "normalization", 0.40, 0.0f, 0.50f);
    p.heightOffset = finiteParam(params, "heightOffset", -0.65, -1.0f, 1.0f);
    p.fadeCenter = finiteParam(params, "fadeCenter", 0.50, 0.0f, 1.0f);
    p.fadeRange = finiteParam(params, "fadeRange", 0.50, 0.01f, 1.0f);

    // The published method derives its fade target from altitude normalized by
    // terrain amplitude. Auto mode fits the equivalent center and 60%-half-span
    // range to this input. Near-flat inputs retain the manual mapping so tiny
    // noise is not expanded into a full signed fade.
    if (p.strength > 1.0e-7f && p.octaves > 0u &&
        params.get("fadeAuto", 1.0) >= 0.5) {
        const float* data = input->data();
        const std::size_t count = input->count();
        if (data && count > 0) {
            float lo = data[0];
            float hi = data[0];
            for (std::size_t i = 1; i < count; ++i) {
                const float value = data[i];
                if (value < lo) lo = value;
                if (value > hi) hi = value;
            }
            const float span = hi - lo;
            if (std::isfinite(span) && span > 1.0e-4f) {
                p.fadeCenter = std::clamp(
                    0.5f * (lo + hi), 0.0f, 1.0f);
                p.fadeRange = std::clamp(
                    0.3f * span, 0.01f, 1.0f);
            }
        }
    }

    return ctx.dispatch2D(
        "erosion_filter_v4", kernels::kErosionFilter, "erosion_filter",
        out.width(), out.height(),
        [&](MTL::ComputeCommandEncoder* encoder) {
            encoder->setBuffer(out.buffer(), 0, 0);
            encoder->setBuffer(input->buffer(), 0, 1);
            encoder->setBytes(&p, sizeof(p), 2);
            encoder->setBuffer(ridge.buffer(), 0, 3);
        },
        error);
}

} // namespace theia
