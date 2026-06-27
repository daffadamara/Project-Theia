#pragma once
#include "Node.hpp"

namespace theia {

// Filter node (1 input): thermal erosion (talus-angle relaxation). Material on
// slopes steeper than the talus angle slides to lower neighbors, producing
// natural scree slopes and softening sharp ridges.
class ThermalErosionNode : public Node {
public:
    explicit ThermalErosionNode(std::string id)
        : Node(std::move(id), "thermal") {
        params.set("iterations", 40);
        params.set("talusAngle", 33.0);   // degrees (~angle of repose)
        params.set("strength", 0.5);      // fraction of excess shed per step
        params.set("cellSize", 1.0);
        params.set("heightScale", 64.0);
    }
    std::size_t inputCount() const override { return 1; }
    bool evaluate(GPUContext& ctx,
                  const std::vector<const Heightfield*>& inputs,
                  Heightfield& out, std::string& error) override;
};

} // namespace theia
