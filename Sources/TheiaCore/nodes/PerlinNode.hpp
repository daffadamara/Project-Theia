#pragma once
#include "Node.hpp"

namespace theia {

// Generator node (0 inputs): fBm Perlin noise. Params: seed, octaves,
// frequency, lacunarity, gain. Wraps generatePerlin().
class PerlinNode : public Node {
public:
    explicit PerlinNode(std::string id) : Node(std::move(id), "perlin") {
        params.set("seed", 1337);
        params.set("octaves", 6);
        params.set("frequency", 4.0);
        params.set("lacunarity", 2.0);
        params.set("gain", 0.5);
    }
    std::size_t inputCount() const override { return 0; }
    bool evaluate(GPUContext& ctx,
                  const std::vector<const Heightfield*>& inputs,
                  Heightfield& out, std::string& error) override;
};

} // namespace theia
