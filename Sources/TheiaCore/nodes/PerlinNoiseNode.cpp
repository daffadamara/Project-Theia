#include "nodes/PerlinNoiseNode.hpp"

#include <Foundation/Foundation.hpp>
#include <Metal/Metal.hpp>
#include <algorithm>

#include "GPUContext.hpp"
#include "Heightfield.hpp"
#include "kernels/Kernels.metal.hpp"

namespace theia {

namespace {
// Must match `struct PerlinParams` in kernels::kPerlinFbm exactly (std140-free,
// all 4-byte scalars, trailing pad keeps it tidy).
struct PerlinParamsGPU {
    std::uint32_t width;
    std::uint32_t height;
    std::uint32_t octaves;
    std::uint32_t seed;
    float frequency;
    float lacunarity;
    float gain;
    float _pad;
};
} // namespace

bool generatePerlin(GPUContext& ctx, Heightfield& hf,
                    const PerlinSettings& s, std::string& error) {
    if (!hf.valid()) {
        error = "invalid heightfield";
        return false;
    }

    MTL::ComputePipelineState* pso =
        ctx.pipeline("perlin_fbm", kernels::kPerlinFbm, "perlin_fbm", error);
    if (!pso) return false;

    NS::AutoreleasePool* pool = NS::AutoreleasePool::alloc()->init();

    PerlinParamsGPU p{};
    p.width = hf.width();
    p.height = hf.height();
    p.octaves = std::max<std::uint32_t>(1, s.octaves);
    p.seed = s.seed;
    p.frequency = s.frequency;
    p.lacunarity = s.lacunarity;
    p.gain = s.gain;

    MTL::CommandBuffer* cb = ctx.queue()->commandBuffer();
    MTL::ComputeCommandEncoder* enc = cb->computeCommandEncoder();
    enc->setComputePipelineState(pso);
    enc->setBuffer(hf.buffer(), 0, 0);
    enc->setBytes(&p, sizeof(p), 1);

    // 2D dispatch: one thread per texel, non-uniform threadgroups (Apple GPU).
    const NS::UInteger w = pso->threadExecutionWidth();
    const NS::UInteger h = std::max<NS::UInteger>(
        1, pso->maxTotalThreadsPerThreadgroup() / w);
    MTL::Size grid(hf.width(), hf.height(), 1);
    MTL::Size tg(w, h, 1);
    enc->dispatchThreads(grid, tg);
    enc->endEncoding();
    cb->commit();
    cb->waitUntilCompleted();

    bool ok = cb->status() == MTL::CommandBufferStatusCompleted;
    if (!ok) {
        error = "perlin command buffer did not complete (status " +
                std::to_string(static_cast<int>(cb->status())) + ")";
    }
    pool->release();
    return ok;
}

} // namespace theia
