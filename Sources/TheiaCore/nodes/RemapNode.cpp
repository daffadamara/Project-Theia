#include "nodes/RemapNode.hpp"

#include <Metal/Metal.hpp>

#include "GPUContext.hpp"
#include "Heightfield.hpp"
#include "kernels/Kernels.metal.hpp"

namespace theia {

bool RemapNode::evaluate(GPUContext& ctx,
                         const std::vector<const Heightfield*>& inputs,
                         Heightfield& out, std::string& error) {
    if (inputs.size() != 1 || !inputs[0]) {
        error = "remap '" + id() + "' requires 1 input";
        return false;
    }
    const float pr[6] = {static_cast<float>(params.get("inLow", 0.0)),
                         static_cast<float>(params.get("inHigh", 1.0)),
                         static_cast<float>(params.get("outLow", 0.0)),
                         static_cast<float>(params.get("outHigh", 1.0)),
                         static_cast<float>(params.get("gamma", 1.0)),
                         static_cast<float>(params.get("clamp", 1.0))};
    const std::uint32_t dim[2] = {out.width(), out.height()};
    const Heightfield* in = inputs[0];

    return ctx.dispatch2D(
        "remap", kernels::kRemap, "remap", out.width(), out.height(),
        [&](MTL::ComputeCommandEncoder* enc) {
            enc->setBuffer(out.buffer(), 0, 0);
            enc->setBuffer(in->buffer(), 0, 1);
            enc->setBytes(pr, sizeof(pr), 2);
            enc->setBytes(dim, sizeof(dim), 3);
        },
        error);
}

} // namespace theia
