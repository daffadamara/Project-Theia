#include "nodes/RiverCarveNode.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <vector>

#include "Heightfield.hpp"

namespace theia {
namespace {

float clamp01(float v) {
    if (!std::isfinite(v)) return 0.0f;
    return std::min(1.0f, std::max(0.0f, v));
}

std::size_t idx(std::uint32_t x, std::uint32_t y, std::uint32_t w) {
    return std::size_t(y) * w + x;
}

std::vector<float> boxBlur(const std::vector<float>& input, std::uint32_t w,
                           std::uint32_t h, int radius, int passes) {
    if (radius <= 0 || passes <= 0) return input;
    std::vector<float> a = input;
    std::vector<float> b(input.size());
    for (int pass = 0; pass < passes; ++pass) {
        for (std::uint32_t y = 0; y < h; ++y) {
            for (std::uint32_t x = 0; x < w; ++x) {
                float sum = 0.0f;
                int count = 0;
                for (int dx = -radius; dx <= radius; ++dx) {
                    const int nx = int(x) + dx;
                    if (nx < 0 || nx >= int(w)) continue;
                    sum += a[idx(std::uint32_t(nx), y, w)];
                    ++count;
                }
                b[idx(x, y, w)] = sum / float(count);
            }
        }
        for (std::uint32_t y = 0; y < h; ++y) {
            for (std::uint32_t x = 0; x < w; ++x) {
                float sum = 0.0f;
                int count = 0;
                for (int dy = -radius; dy <= radius; ++dy) {
                    const int ny = int(y) + dy;
                    if (ny < 0 || ny >= int(h)) continue;
                    sum += b[idx(x, std::uint32_t(ny), w)];
                    ++count;
                }
                a[idx(x, y, w)] = sum / float(count);
            }
        }
    }
    return a;
}

} // namespace

bool RiverCarveNode::evaluate(GPUContext&,
                              const std::vector<const Heightfield*>& inputs,
                              Heightfield& out, std::string& error) {
    if (inputs.size() != 2 || !inputs[0] || !inputs[1]) {
        error = "rivercarve '" + id() + "' requires terrain and mask inputs";
        return false;
    }
    const Heightfield* terrain = inputs[0];
    const Heightfield* maskField = inputs[1];
    if (terrain->width() != maskField->width() ||
        terrain->height() != maskField->height()) {
        error = "rivercarve: input sizes differ";
        return false;
    }

    const std::uint32_t w = terrain->width();
    const std::uint32_t h = terrain->height();
    std::vector<float> mask(maskField->data(), maskField->data() + maskField->count());
    for (float& v : mask) v = clamp01(v);

    const float depth = clamp01(static_cast<float>(params.get("depth", 0.45)));
    const float downcutting =
        clamp01(static_cast<float>(params.get("downcutting", 0.55)));
    const float valleyWidth =
        std::min(12.0f, std::max(0.0f, static_cast<float>(params.get("riverValleyWidth", 2.0))));
    const int valleyRadius = std::max(1, int(std::ceil(1.0f + valleyWidth * 2.0f)));
    const std::vector<float> valley = boxBlur(mask, w, h, valleyRadius, 2);
    const float shorelineWidth =
        std::min(12.0f, std::max(0.0f, static_cast<float>(params.get("shorelineWidth", 2.0))));
    const float shorelineSharpness =
        clamp01(static_cast<float>(params.get("shorelineSharpness", 0.45)));
    const int shoreRadius = std::max(1, int(std::ceil(shorelineWidth)));
    // Shoreline/bank falloff expands the river mask into a local envelope, then
    // blends that soft envelope back toward the raw channel mask. This shapes
    // the primary cut profile itself; otherwise the binary river mask keeps
    // producing a hard cliff no matter how wide the shoreline shelf is.
    std::vector<float> shore = boxBlur(mask, w, h, shoreRadius, 3);
    for (float& v : shore) {
        v = clamp01(v);
    }

    const float channelCut = depth * (0.035f + 0.18f * downcutting);
    const float valleyCut = depth * (0.010f + 0.045f * downcutting);
    const float rawChannelMix =
        shorelineWidth <= 0.0f ? 1.0f : (0.08f + shorelineSharpness * 0.42f);
    const float shoreExponent = 0.50f + shorelineSharpness * 1.25f;
    for (std::size_t i = 0; i < mask.size(); ++i) {
        const float base = clamp01(terrain->data()[i]);
        const float softenedChannel = std::pow(shore[i], shoreExponent);
        const float carveProfile =
            clamp01(softenedChannel * (1.0f - rawChannelMix) +
                    mask[i] * rawChannelMix);
        out.data()[i] =
            clamp01(base - channelCut * carveProfile - valleyCut * valley[i]);
    }
    return true;
}

} // namespace theia
