#include "nodes/ClampNode.hpp"

#include <algorithm>
#include <Metal/Metal.hpp>

#include "GPUContext.hpp"
#include "Heightfield.hpp"
#include "kernels/Kernels.metal.hpp"

namespace theia {

bool ClampNode::evaluate(GPUContext& ctx,
                         const std::vector<const Heightfield*>& inputs,
                         Heightfield& out, std::string& error) {
    if (inputs.size() != 1 || !inputs[0]) {
        error = "clamp '" + id() + "' requires 1 input";
        return false;
    }
    float lo = static_cast<float>(params.get("min", 0.0));
    float hi = static_cast<float>(params.get("max", 1.0));
    if (lo > hi) std::swap(lo, hi);
    const float range[2] = {lo, hi};
    const std::uint32_t dim[2] = {out.width(), out.height()};
    const Heightfield* in = inputs[0];

    return ctx.dispatch2D(
        "clamp", kernels::kClampNode, "clamp_node", out.width(), out.height(),
        [&](MTL::ComputeCommandEncoder* enc) {
            enc->setBuffer(out.buffer(), 0, 0);
            enc->setBuffer(in->buffer(), 0, 1);
            enc->setBytes(range, sizeof(range), 2);
            enc->setBytes(dim, sizeof(dim), 3);
        },
        error);
}

} // namespace theia
