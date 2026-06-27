#include "nodes/CombineNode.hpp"

#include <Metal/Metal.hpp>

#include "GPUContext.hpp"
#include "Heightfield.hpp"
#include "kernels/Kernels.metal.hpp"

namespace theia {

bool CombineNode::evaluate(GPUContext& ctx,
                           const std::vector<const Heightfield*>& inputs,
                           Heightfield& out, std::string& error) {
    if (inputs.size() != 2 || !inputs[0] || !inputs[1]) {
        error = "combine '" + id() + "' requires 2 inputs";
        return false;
    }
    const float t = static_cast<float>(params.get("t", 0.5));
    const std::uint32_t dim[2] = {out.width(), out.height()};
    const Heightfield* a = inputs[0];
    const Heightfield* b = inputs[1];

    return ctx.dispatch2D(
        "combine", kernels::kCombine, "combine", out.width(), out.height(),
        [&](MTL::ComputeCommandEncoder* enc) {
            enc->setBuffer(out.buffer(), 0, 0);
            enc->setBuffer(a->buffer(), 0, 1);
            enc->setBuffer(b->buffer(), 0, 2);
            enc->setBytes(&t, sizeof(t), 3);
            enc->setBytes(dim, sizeof(dim), 4);
        },
        error);
}

} // namespace theia
