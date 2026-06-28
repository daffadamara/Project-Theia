#pragma once
#include "Node.hpp"

namespace theia {

// Utility node (1 input): remap an input interval to an output interval with
// optional pre-gamma clamping.
class RemapNode : public Node {
public:
    explicit RemapNode(std::string id) : Node(std::move(id), "remap") {
        params.set("inLow", 0.0);
        params.set("inHigh", 1.0);
        params.set("outLow", 0.0);
        params.set("outHigh", 1.0);
        params.set("gamma", 1.0);
        params.set("clamp", 1.0);
    }
    std::size_t inputCount() const override { return 1; }
    bool evaluate(GPUContext& ctx,
                  const std::vector<const Heightfield*>& inputs,
                  Heightfield& out, std::string& error) override;
};

} // namespace theia
