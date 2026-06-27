#pragma once
#include "Node.hpp"

namespace theia {

// Filter node (1 input): hydraulic erosion via the Mei et al. 2007 virtual-pipes
// shallow-water model. Carves drainage networks and deposits sediment.
class HydraulicErosionNode : public Node {
public:
    explicit HydraulicErosionNode(std::string id)
        : Node(std::move(id), "hydraulic") {
        params.set("iterations", 60);
        params.set("rain", 0.012);
        params.set("evaporation", 0.015);
        params.set("sedimentCapacity", 0.6);
        params.set("suspension", 0.5);
        params.set("deposition", 0.5);
        params.set("gravity", 9.81);
        params.set("dt", 0.02);
        params.set("minTilt", 0.05);
        params.set("heightScale", 64.0);
        params.set("pipeArea", 1.0);
        params.set("pipeLength", 1.0);
        params.set("cellSize", 1.0);
    }
    std::size_t inputCount() const override { return 1; }
    bool evaluate(GPUContext& ctx,
                  const std::vector<const Heightfield*>& inputs,
                  Heightfield& out, std::string& error) override;
};

} // namespace theia
