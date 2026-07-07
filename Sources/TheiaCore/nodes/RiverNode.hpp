#pragma once
#include "Node.hpp"

namespace theia {

// Terrain-tracing river mask node inspired by Gaea's Rivers/HydroFix workflow.
// It reads the upstream heightfield directly, selects high headwaters, and
// traces downhill/breached paths toward lower outlets.
class RiverNode : public Node {
public:
    explicit RiverNode(std::string id);
    std::size_t inputCount() const override { return 1; }
    bool evaluate(GPUContext& ctx,
                  const std::vector<const Heightfield*>& inputs,
                  Heightfield& out, std::string& error) override;
};

} // namespace theia
