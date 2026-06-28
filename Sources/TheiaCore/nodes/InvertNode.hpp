#pragma once
#include "Node.hpp"

namespace theia {

// Utility node (1 input): crossfade between input and its inverse.
class InvertNode : public Node {
public:
    explicit InvertNode(std::string id) : Node(std::move(id), "invert") {
        params.set("amount", 1.0);
    }
    std::size_t inputCount() const override { return 1; }
    bool evaluate(GPUContext& ctx,
                  const std::vector<const Heightfield*>& inputs,
                  Heightfield& out, std::string& error) override;
};

} // namespace theia
