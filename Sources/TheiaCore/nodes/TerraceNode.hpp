#pragma once
#include "Node.hpp"

namespace theia {

// Filter node (1 input): quantize heights into stratified terraces.
class TerraceNode : public Node {
public:
    explicit TerraceNode(std::string id) : Node(std::move(id), "terrace") {
        params.set("steps", 8);
        params.set("sharpness", 3.0);
    }
    std::size_t inputCount() const override { return 1; }
    bool evaluate(GPUContext& ctx,
                  const std::vector<const Heightfield*>& inputs,
                  Heightfield& out, std::string& error) override;
};

} // namespace theia
