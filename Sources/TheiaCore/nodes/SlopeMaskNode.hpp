#pragma once
#include "Node.hpp"

namespace theia {

// Filter node (1 input): emit a [0,1] mask from terrain steepness.
class SlopeMaskNode : public Node {
public:
    explicit SlopeMaskNode(std::string id) : Node(std::move(id), "slopemask") {
        params.set("low", 0.2);
        params.set("high", 0.8);
        params.set("heightScale", 64.0);
        params.set("cellSize", 1.0);
    }
    std::size_t inputCount() const override { return 1; }
    bool evaluate(GPUContext& ctx,
                  const std::vector<const Heightfield*>& inputs,
                  Heightfield& out, std::string& error) override;
};

} // namespace theia
