#pragma once
#include "Node.hpp"

namespace theia {

// Carve terrain from a separate river mask. Input 0 = terrain, input 1 = mask.
class RiverCarveNode : public Node {
public:
    explicit RiverCarveNode(std::string id) : Node(std::move(id), "rivercarve") {
        params.set("depth", 0.45);
        params.set("downcutting", 0.55);
        params.set("riverValleyWidth", 2.0);
        params.set("shorelineWidth", 2.0);
        params.set("shorelineSharpness", 0.45);
    }
    std::size_t inputCount() const override { return 2; }
    bool evaluate(GPUContext& ctx,
                  const std::vector<const Heightfield*>& inputs,
                  Heightfield& out, std::string& error) override;
};

} // namespace theia
