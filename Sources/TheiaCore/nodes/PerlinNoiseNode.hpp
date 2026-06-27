#pragma once
//
// Perlin fBm generator. For M1 this is a free function used directly; M2 will
// wrap it in a graph Node. PRIVATE header.
//
#include <cstdint>
#include <string>

namespace theia {

class GPUContext;
class Heightfield;

// CPU-side mirror of the MSL `PerlinParams` struct (must stay layout-compatible).
struct PerlinSettings {
    std::uint32_t seed = 1337;
    std::uint32_t octaves = 6;
    float frequency = 4.0f;
    float lacunarity = 2.0f;
    float gain = 0.5f;
    float heightScale = 1.0f;
};

// Fill `hf` with fBm Perlin noise in [0,1]. Returns false + sets `error` on
// failure. Synchronous (waits for GPU completion).
bool generatePerlin(GPUContext& ctx, Heightfield& hf,
                    const PerlinSettings& s, std::string& error);

} // namespace theia
