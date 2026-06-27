#include "nodes/PerlinNode.hpp"

#include "Heightfield.hpp"
#include "nodes/PerlinNoiseNode.hpp"

namespace theia {

bool PerlinNode::evaluate(GPUContext& ctx,
                          const std::vector<const Heightfield*>& /*inputs*/,
                          Heightfield& out, std::string& error) {
    PerlinSettings s;
    s.seed = static_cast<std::uint32_t>(params.get("seed", 1337));
    s.octaves = static_cast<std::uint32_t>(params.get("octaves", 6));
    s.frequency = static_cast<float>(params.get("frequency", 4.0));
    s.lacunarity = static_cast<float>(params.get("lacunarity", 2.0));
    s.gain = static_cast<float>(params.get("gain", 0.5));
    s.heightScale = static_cast<float>(params.get("heightScale", 1.0));
    return generatePerlin(ctx, out, s, error);
}

} // namespace theia
