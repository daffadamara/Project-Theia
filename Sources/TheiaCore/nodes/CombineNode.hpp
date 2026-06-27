#pragma once
#include "Node.hpp"

namespace theia {

// Combine node (2 inputs): out = clamp(mix(a, b, t), 0, 1). Param: t in [0,1].
class CombineNode : public Node {
public:
    explicit CombineNode(std::string id) : Node(std::move(id), "combine") {
        params.set("t", 0.5);
    }
    std::size_t inputCount() const override { return 2; }
    bool evaluate(GPUContext& ctx,
                  const std::vector<const Heightfield*>& inputs,
                  Heightfield& out, std::string& error) override;
};

} // namespace theia
