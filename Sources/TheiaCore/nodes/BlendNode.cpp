#include "nodes/BlendNode.hpp"

#include <Metal/Metal.hpp>

#include "GPUContext.hpp"
#include "Heightfield.hpp"
#include "kernels/Kernels.metal.hpp"

namespace theia {

bool BlendNode::evaluate(GPUContext& ctx,
                         const std::vector<const Heightfield*>& inputs,
                         Heightfield& out, std::string& error) {
    if (inputs.size() != 2 || !inputs[0] || !inputs[1]) {
        error = "blend '" + id() + "' requires 2 inputs";
        return false;
    }
    const float pr[2] = {static_cast<float>(params.get("mode", 0.0)),
                         static_cast<float>(params.get("opacity", 1.0))};
    const std::uint32_t dim[2] = {out.width(), out.height()};
    const Heightfield* a = inputs[0];
    const Heightfield* b = inputs[1];

    return ctx.dispatch2D(
        "blend", kernels::kBlend, "blend", out.width(), out.height(),
        [&](MTL::ComputeCommandEncoder* enc) {
            enc->setBuffer(out.buffer(), 0, 0);
            enc->setBuffer(a->buffer(), 0, 1);
            enc->setBuffer(b->buffer(), 0, 2);
            enc->setBytes(pr, sizeof(pr), 3);
            enc->setBytes(dim, sizeof(dim), 4);
        },
        error);
}

} // namespace theia
