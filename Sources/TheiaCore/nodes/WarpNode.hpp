#pragma once
#include "Node.hpp"

namespace theia {

// Filter node (1 input): domain-warp the source heightfield with deterministic
// procedural displacement.
class WarpNode : public Node {
public:
    explicit WarpNode(std::string id) : Node(std::move(id), "warp") {
        params.set("seed", 9001);
        params.set("octaves", 3);
        params.set("frequency", 3.0);
        params.set("strength", 0.05);
    }
    std::size_t inputCount() const override { return 1; }
    bool evaluate(GPUContext& ctx,
                  const std::vector<const Heightfield*>& inputs,
                  Heightfield& out, std::string& error) override;
};

} // namespace theia
