#pragma once
#include "Node.hpp"

namespace theia {

// Utility node (1 input): restrict heights to a configurable band.
class ClampNode : public Node {
public:
    explicit ClampNode(std::string id) : Node(std::move(id), "clamp") {
        params.set("min", 0.0);
        params.set("max", 1.0);
    }
    std::size_t inputCount() const override { return 1; }
    bool evaluate(GPUContext& ctx,
                  const std::vector<const Heightfield*>& inputs,
                  Heightfield& out, std::string& error) override;
};

} // namespace theia
