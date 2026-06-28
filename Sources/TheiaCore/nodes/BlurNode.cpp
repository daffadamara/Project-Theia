#include "nodes/BlurNode.hpp"

#include <algorithm>
#include <Metal/Metal.hpp>

#include "GPUContext.hpp"
#include "Heightfield.hpp"
#include "kernels/Kernels.metal.hpp"

namespace theia {

bool BlurNode::evaluate(GPUContext& ctx,
                        const std::vector<const Heightfield*>& inputs,
                        Heightfield& out, std::string& error) {
    if (inputs.size() != 1 || !inputs[0]) {
        error = "blur '" + id() + "' requires 1 input";
        return false;
    }
    const float radius = static_cast<float>(
        std::clamp(params.get("radius", 2.0), 0.0, 16.0));
    const float strength = static_cast<float>(params.get("strength", 1.0));
    const float pr[2] = {radius, strength};
    const std::uint32_t dim[2] = {out.width(), out.height()};
    const Heightfield* in = inputs[0];

    return ctx.dispatch2D(
        "blur", kernels::kBlur, "blur", out.width(), out.height(),
        [&](MTL::ComputeCommandEncoder* enc) {
            enc->setBuffer(out.buffer(), 0, 0);
            enc->setBuffer(in->buffer(), 0, 1);
            enc->setBytes(pr, sizeof(pr), 2);
            enc->setBytes(dim, sizeof(dim), 3);
        },
        error);
}

} // namespace theia
