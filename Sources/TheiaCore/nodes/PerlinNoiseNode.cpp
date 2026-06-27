#include "nodes/PerlinNoiseNode.hpp"

#include <Metal/Metal.hpp>
#include <algorithm>

#include "GPUContext.hpp"
#include "Heightfield.hpp"
#include "kernels/Kernels.metal.hpp"

namespace theia {

namespace {
// Must match `struct PerlinParams` in kernels::kPerlinFbm exactly (all 4-byte
// scalars, trailing pad keeps it tidy).
struct PerlinParamsGPU {
    std::uint32_t width;
    std::uint32_t height;
    std::uint32_t octaves;
    std::uint32_t seed;
    float frequency;
    float lacunarity;
    float gain;
    float _pad;
};
} // namespace

bool generatePerlin(GPUContext& ctx, Heightfield& hf,
                    const PerlinSettings& s, std::string& error) {
    if (!hf.valid()) {
        error = "invalid heightfield";
        return false;
    }

    PerlinParamsGPU p{};
    p.width = hf.width();
    p.height = hf.height();
    p.octaves = std::max<std::uint32_t>(1, s.octaves);
    p.seed = s.seed;
    p.frequency = s.frequency;
    p.lacunarity = s.lacunarity;
    p.gain = s.gain;

    return ctx.dispatch2D(
        "perlin_fbm", kernels::kPerlinFbm, "perlin_fbm", hf.width(), hf.height(),
        [&](MTL::ComputeCommandEncoder* enc) {
            enc->setBuffer(hf.buffer(), 0, 0);
            enc->setBytes(&p, sizeof(p), 1);
        },
        error);
}

} // namespace theia
