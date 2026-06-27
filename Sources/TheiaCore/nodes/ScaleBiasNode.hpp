#pragma once
#include "Node.hpp"

namespace theia {

// Filter node (1 input): elementwise out = clamp(in * scale + bias, 0, 1).
class ScaleBiasNode : public Node {
public:
    explicit ScaleBiasNode(std::string id) : Node(std::move(id), "scalebias") {
        params.set("scale", 1.0);
        params.set("bias", 0.0);
    }
    std::size_t inputCount() const override { return 1; }
    bool evaluate(GPUContext& ctx,
                  const std::vector<const Heightfield*>& inputs,
                  Heightfield& out, std::string& error) override;
};

} // namespace theia
