#include "nodes/WarpNode.hpp"

#include <Metal/Metal.hpp>

#include "GPUContext.hpp"
#include "Heightfield.hpp"
#include "kernels/Kernels.metal.hpp"

namespace theia {

bool WarpNode::evaluate(GPUContext& ctx,
                        const std::vector<const Heightfield*>& inputs,
                        Heightfield& out, std::string& error) {
    if (inputs.size() != 1 || !inputs[0]) {
        error = "warp '" + id() + "' requires 1 input";
        return false;
    }
    const std::uint32_t ui[4] = {
        out.width(),
        out.height(),
        static_cast<std::uint32_t>(params.get("octaves", 3)),
        static_cast<std::uint32_t>(params.get("seed", 9001))};
    const float pr[2] = {static_cast<float>(params.get("frequency", 3.0)),
                         static_cast<float>(params.get("strength", 0.05))};
    const Heightfield* in = inputs[0];

    return ctx.dispatch2D(
        "warp", kernels::kWarp, "warp", out.width(), out.height(),
        [&](MTL::ComputeCommandEncoder* enc) {
            enc->setBuffer(out.buffer(), 0, 0);
            enc->setBuffer(in->buffer(), 0, 1);
            enc->setBytes(ui, sizeof(ui), 2);
            enc->setBytes(pr, sizeof(pr), 3);
        },
        error);
}

} // namespace theia
