#pragma once
#include "Node.hpp"

namespace theia {

// Generator node (0 inputs): ridged multifractal-style fBm.
class RidgedNode : public Node {
public:
    explicit RidgedNode(std::string id) : Node(std::move(id), "ridged") {
        params.set("seed", 2027);
        params.set("octaves", 6);
        params.set("frequency", 4.0);
        params.set("lacunarity", 2.0);
        params.set("gain", 0.5);
        params.set("ridgeSharpness", 2.0);
        params.set("heightScale", 1.0);
    }
    std::size_t inputCount() const override { return 0; }
    bool evaluate(GPUContext& ctx,
                  const std::vector<const Heightfield*>& inputs,
                  Heightfield& out, std::string& error) override;
};

} // namespace theia
