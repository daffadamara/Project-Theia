#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace theia {

struct HydrologyParams {
    std::uint32_t seed = 1337;
    std::uint32_t particles = 8000;
    std::uint32_t maxAge = 80;
    float evaporation = 0.01f;
    float deposition = 0.12f;
    float entrainment = 8.0f;
    float gravity = 1.0f;
    float momentumTransfer = 0.8f;
    float settling = 0.35f;
    float maxDiff = 0.02f;
    float heightScale = 64.0f;
};

struct HydrologyResult {
    std::vector<float> terrain;
    std::vector<float> discharge;
};

// CPU reference implementation of the SimpleHydrology/Nick McDonald style
// particle hydrology model. Kept deterministic and dependency-free for Phase 7.
bool runHydrologySimulation(const float* input, std::uint32_t width,
                            std::uint32_t height, const HydrologyParams& params,
                            HydrologyResult& result, std::string& error);

} // namespace theia

