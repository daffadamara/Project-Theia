#include "nodes/ScaleBiasNode.hpp"

#include <Metal/Metal.hpp>

#include "GPUContext.hpp"
#include "Heightfield.hpp"
#include "kernels/Kernels.metal.hpp"

namespace theia {

bool ScaleBiasNode::evaluate(GPUContext& ctx,
                             const std::vector<const Heightfield*>& inputs,
                             Heightfield& out, std::string& error) {
    if (inputs.size() != 1 || !inputs[0]) {
        error = "scalebias '" + id() + "' requires 1 input";
        return false;
    }
    const float sb[2] = {static_cast<float>(params.get("scale", 1.0)),
                         static_cast<float>(params.get("bias", 0.0))};
    const std::uint32_t dim[2] = {out.width(), out.height()};
    const Heightfield* in = inputs[0];

    return ctx.dispatch2D(
        "scalebias", kernels::kScaleBias, "scalebias", out.width(), out.height(),
        [&](MTL::ComputeCommandEncoder* enc) {
            enc->setBuffer(out.buffer(), 0, 0);
            enc->setBuffer(in->buffer(), 0, 1);
            enc->setBytes(sb, sizeof(sb), 2);
            enc->setBytes(dim, sizeof(dim), 3);
        },
        error);
}

} // namespace theia
