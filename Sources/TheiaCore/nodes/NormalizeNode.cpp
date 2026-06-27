#include "nodes/NormalizeNode.hpp"

#include <Metal/Metal.hpp>

#include "GPUContext.hpp"
#include "Heightfield.hpp"
#include "kernels/Kernels.metal.hpp"

namespace theia {

bool NormalizeNode::evaluate(GPUContext& ctx,
                             const std::vector<const Heightfield*>& inputs,
                             Heightfield& out, std::string& error) {
    if (inputs.size() != 1 || !inputs[0]) {
        error = "normalize '" + id() + "' requires 1 input";
        return false;
    }
    const Heightfield* in = inputs[0];

    // Min/max from a CPU scan of the shared input buffer, then an affine remap
    // reusing the scalebias kernel: out = in * (1/range) + (-min/range).
    float mn, mx;
    double mean, var;
    in->stats(mn, mx, mean, var);
    const float range = (mx > mn) ? (mx - mn) : 1.0f;
    const float sb[2] = {1.0f / range, -mn / range};
    const std::uint32_t dim[2] = {out.width(), out.height()};

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
