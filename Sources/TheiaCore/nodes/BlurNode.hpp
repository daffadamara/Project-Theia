#pragma once
#include "Node.hpp"

namespace theia {

// Filter node (1 input): deterministic clamped-edge box blur mixed with input.
class BlurNode : public Node {
public:
    explicit BlurNode(std::string id) : Node(std::move(id), "blur") {
        params.set("radius", 2.0);
        params.set("strength", 1.0);
    }
    std::size_t inputCount() const override { return 1; }
    bool evaluate(GPUContext& ctx,
                  const std::vector<const Heightfield*>& inputs,
                  Heightfield& out, std::string& error) override;
};

} // namespace theia
