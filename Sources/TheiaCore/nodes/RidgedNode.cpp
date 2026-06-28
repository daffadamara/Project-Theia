#include "nodes/RidgedNode.hpp"

#include <Metal/Metal.hpp>

#include "GPUContext.hpp"
#include "Heightfield.hpp"
#include "kernels/Kernels.metal.hpp"

namespace theia {

bool RidgedNode::evaluate(GPUContext& ctx,
                          const std::vector<const Heightfield*>& /*inputs*/,
                          Heightfield& out, std::string& error) {
    const std::uint32_t ui[4] = {
        out.width(),
        out.height(),
        static_cast<std::uint32_t>(params.get("octaves", 6)),
        static_cast<std::uint32_t>(params.get("seed", 2027))};
    const float pr[5] = {static_cast<float>(params.get("frequency", 4.0)),
                         static_cast<float>(params.get("lacunarity", 2.0)),
                         static_cast<float>(params.get("gain", 0.5)),
                         static_cast<float>(params.get("ridgeSharpness", 2.0)),
                         static_cast<float>(params.get("heightScale", 1.0))};

    return ctx.dispatch2D(
        "ridged", kernels::kRidgedFbm, "ridged_fbm", out.width(), out.height(),
        [&](MTL::ComputeCommandEncoder* enc) {
            enc->setBuffer(out.buffer(), 0, 0);
            enc->setBytes(ui, sizeof(ui), 1);
            enc->setBytes(pr, sizeof(pr), 2);
        },
        error);
}

} // namespace theia
