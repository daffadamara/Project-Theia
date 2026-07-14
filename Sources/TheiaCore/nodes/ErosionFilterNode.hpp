#pragma once

#include "Node.hpp"

namespace theia {

// Experimental one-pass procedural gully filter. Unlike the simulation-based
// erosion nodes, every output texel can be evaluated independently.
class ErosionFilterNode : public Node {
public:
    explicit ErosionFilterNode(std::string id)
        : Node(std::move(id), "erosionfilter") {
        params.set("seed", 1337);
        params.set("scale", 0.15);
        params.set("strength", 0.22);
        params.set("octaves", 5);
        params.set("lacunarity", 2.0);
        params.set("gain", 0.50);
        params.set("gullyWeight", 0.50);
        params.set("detail", 1.50);
        params.set("ridgeRounding", 0.10);
        params.set("creaseRounding", 0.00);
        params.set("onset", 1.25);
        params.set("assumedSlope", 0.70);
        params.set("slopeMix", 1.00);
        params.set("cellScale", 0.70);
        params.set("normalization", 0.50);
        params.set("heightOffset", -0.65);
        params.set("fadeCenter", 0.50);
        params.set("fadeRange", 0.50);
    }

    std::size_t inputCount() const override { return 1; }
    bool evaluate(GPUContext& ctx,
                  const std::vector<const Heightfield*>& inputs,
                  Heightfield& out, std::string& error) override;
    bool evaluateOutputs(GPUContext& ctx,
                         const std::vector<const Heightfield*>& inputs,
                         const std::vector<Heightfield*>& outputs,
                         std::string& error) override;

private:
    bool evaluatePair(GPUContext& ctx,
                      const std::vector<const Heightfield*>& inputs,
                      Heightfield& height, Heightfield& ridge,
                      std::string& error);
};

} // namespace theia
