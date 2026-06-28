#pragma once
#include "Node.hpp"

namespace theia {

// Combine node (2 inputs): richer blend-mode compositor. mode values:
// 0=mix, 1=add, 2=multiply, 3=max, 4=min, 5=screen.
class BlendNode : public Node {
public:
    explicit BlendNode(std::string id) : Node(std::move(id), "blend") {
        params.set("mode", 0.0);
        params.set("opacity", 1.0);
    }
    std::size_t inputCount() const override { return 2; }
    bool evaluate(GPUContext& ctx,
                  const std::vector<const Heightfield*>& inputs,
                  Heightfield& out, std::string& error) override;
};

} // namespace theia
