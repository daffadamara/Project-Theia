#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace theia {

// Build interleaved RGBA float weights for one base and up to three overlays.
// Missing overlay entries are represented by nullptr. See the approved
// material-layer-stack research note for the normalization contract.
bool buildMaterialWeights(const std::array<const float*, 3>& overlays,
                          const std::array<std::string, 3>& layerIds,
                          std::size_t count,
                          std::vector<float>& weightsRGBA,
                          std::string& error);

// Quantize interleaved normalized weights with largest-remainder allocation so
// every RGBA texel has an exact byte sum of 255.
bool quantizeMaterialWeightsRGBA8(const float* weightsRGBA,
                                  std::size_t texelCount,
                                  std::vector<std::uint8_t>& bytes,
                                  std::string& error);

} // namespace theia
