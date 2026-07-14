#include "MaterialWeights.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <numeric>

namespace theia {

bool buildMaterialWeights(const std::array<const float*, 3>& overlays,
                          const std::array<std::string, 3>& layerIds,
                          std::size_t count,
                          std::vector<float>& weightsRGBA,
                          std::string& error) {
    weightsRGBA.assign(count * 4, 0.0f);
    for (std::size_t texel = 0; texel < count; ++texel) {
        std::array<float, 3> mask{};
        float sum = 0.0f;
        for (std::size_t layer = 0; layer < overlays.size(); ++layer) {
            if (!overlays[layer]) continue;
            const float value = overlays[layer][texel];
            if (!std::isfinite(value)) {
                error = "material layer '" + layerIds[layer] +
                        "' contains non-finite value at texel " +
                        std::to_string(texel);
                weightsRGBA.clear();
                return false;
            }
            mask[layer] = std::clamp(value, 0.0f, 1.0f);
            sum += mask[layer];
        }

        const std::size_t out = texel * 4;
        if (sum <= 1.0f) {
            weightsRGBA[out] = 1.0f - sum;
            for (std::size_t layer = 0; layer < mask.size(); ++layer) {
                weightsRGBA[out + layer + 1] = mask[layer];
            }
        } else {
            weightsRGBA[out] = 0.0f;
            const float inverse = 1.0f / sum;
            for (std::size_t layer = 0; layer < mask.size(); ++layer) {
                weightsRGBA[out + layer + 1] = mask[layer] * inverse;
            }
        }
    }
    return true;
}

bool quantizeMaterialWeightsRGBA8(const float* weightsRGBA,
                                  std::size_t texelCount,
                                  std::vector<std::uint8_t>& bytes,
                                  std::string& error) {
    if (!weightsRGBA && texelCount > 0) {
        error = "material weight quantization received null data";
        return false;
    }
    bytes.assign(texelCount * 4, 0);
    for (std::size_t texel = 0; texel < texelCount; ++texel) {
        std::array<int, 4> quantized{};
        std::array<double, 4> remainder{};
        int total = 0;
        for (std::size_t channel = 0; channel < 4; ++channel) {
            const float weight = weightsRGBA[texel * 4 + channel];
            if (!std::isfinite(weight) || weight < -1e-6f || weight > 1.000001f) {
                error = "invalid normalized material weight at texel " +
                        std::to_string(texel);
                bytes.clear();
                return false;
            }
            const double scaled = 255.0 * std::clamp(double(weight), 0.0, 1.0);
            quantized[channel] = static_cast<int>(std::floor(scaled));
            remainder[channel] = scaled - quantized[channel];
            total += quantized[channel];
        }
        int missing = 255 - total;
        if (missing < 0 || missing > 3) {
            error = "material weights do not sum to one at texel " +
                    std::to_string(texel);
            bytes.clear();
            return false;
        }
        std::array<std::size_t, 4> order{0, 1, 2, 3};
        std::stable_sort(order.begin(), order.end(), [&](std::size_t a,
                                                         std::size_t b) {
            return remainder[a] > remainder[b];
        });
        for (int i = 0; i < missing; ++i) ++quantized[order[std::size_t(i)]];
        for (std::size_t channel = 0; channel < 4; ++channel) {
            bytes[texel * 4 + channel] =
                static_cast<std::uint8_t>(quantized[channel]);
        }
    }
    return true;
}

} // namespace theia
