#pragma once
#include "Node.hpp"

namespace theia {

// Particle hydrology terrain node inspired by SimpleHydrology and Nick
// McDonald's meandering-rivers writeup. CPU reference implementation.
class DropletErosionNode : public Node {
public:
    explicit DropletErosionNode(std::string id);
    std::size_t inputCount() const override { return 1; }
    bool evaluate(GPUContext& ctx,
                  const std::vector<const Heightfield*>& inputs,
                  Heightfield& out, std::string& error) override;
};

void setHydrologyDefaults(ParamSet& params);

} // namespace theia

