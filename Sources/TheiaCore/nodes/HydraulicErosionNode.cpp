#include "nodes/HydraulicErosionNode.hpp"

#include <Foundation/Foundation.hpp>
#include <Metal/Metal.hpp>
#include <algorithm>

#include "GPUContext.hpp"
#include "Heightfield.hpp"
#include "kernels/Erosion.metal.hpp"

namespace theia {

namespace {
// Must match `struct HydroParams` in kernels::kHydraulic exactly.
struct HydroParamsGPU {
    std::uint32_t width;
    std::uint32_t height;
    float dt;
    float rain;
    float evaporation;
    float gravity;
    float pipeArea;
    float pipeLength;
    float cellSize;
    float sedimentCap;
    float suspension;
    float deposition;
    float minTilt;
    float heightScale;
};
} // namespace

bool HydraulicErosionNode::evaluate(GPUContext& ctx,
                                    const std::vector<const Heightfield*>& inputs,
                                    Heightfield& out, std::string& error) {
    if (inputs.size() != 1 || !inputs[0]) {
        error = "hydraulic '" + id() + "' requires 1 input";
        return false;
    }
    const Heightfield* in = inputs[0];
    const std::uint32_t W = out.width(), H = out.height();
    const std::size_t n = std::size_t(W) * H;
    const int iterations =
        std::max(1, static_cast<int>(params.get("iterations", 60)));

    HydroParamsGPU P{};
    P.width = W;
    P.height = H;
    P.dt = static_cast<float>(params.get("dt", 0.02));
    P.rain = static_cast<float>(params.get("rain", 0.012));
    P.evaporation = static_cast<float>(params.get("evaporation", 0.015));
    P.gravity = static_cast<float>(params.get("gravity", 9.81));
    P.pipeArea = static_cast<float>(params.get("pipeArea", 1.0));
    P.pipeLength = static_cast<float>(params.get("pipeLength", 1.0));
    P.cellSize = static_cast<float>(params.get("cellSize", 1.0));
    P.sedimentCap = static_cast<float>(params.get("sedimentCapacity", 0.6));
    P.suspension = static_cast<float>(params.get("suspension", 0.5));
    P.deposition = static_cast<float>(params.get("deposition", 0.5));
    P.minTilt = static_cast<float>(params.get("minTilt", 0.05));
    P.heightScale = static_cast<float>(params.get("heightScale", 64.0));

    // Compile all passes (cached after first use).
    struct Pass { const char* fn; MTL::ComputePipelineState* pso; };
    Pass passes[] = {
        {"hydro_init", nullptr},  {"hydro_rain", nullptr},
        {"hydro_flux", nullptr},  {"hydro_water", nullptr},
        {"hydro_erode", nullptr}, {"hydro_advect", nullptr},
        {"hydro_evap", nullptr},  {"hydro_finish", nullptr},
    };
    for (auto& p : passes) {
        p.pso = ctx.pipeline(p.fn, kernels::kHydraulic, p.fn, error);
        if (!p.pso) return false;
    }
    auto pso = [&](const char* fn) -> MTL::ComputePipelineState* {
        for (auto& p : passes) if (std::string(fn) == p.fn) return p.pso;
        return nullptr;
    };

    NS::AutoreleasePool* pool = NS::AutoreleasePool::alloc()->init();
    MTL::Device* dev = ctx.device();

    auto mk = [&](std::size_t bytes) {
        return dev->newBuffer(bytes, MTL::ResourceStorageModeShared);
    };
    MTL::Buffer* terrainA = mk(n * sizeof(float));
    MTL::Buffer* terrainB = mk(n * sizeof(float));
    MTL::Buffer* water = mk(n * sizeof(float));
    MTL::Buffer* flux = mk(n * sizeof(float) * 4);
    MTL::Buffer* vel = mk(n * sizeof(float) * 2);
    MTL::Buffer* sedA = mk(n * sizeof(float));
    MTL::Buffer* sedB = mk(n * sizeof(float));

    MTL::Buffer* owned[] = {terrainA, terrainB, water, flux, vel, sedA, sedB};
    bool allocOk = true;
    for (auto* b : owned) allocOk = allocOk && (b != nullptr);
    if (!allocOk) {
        for (auto* b : owned) if (b) b->release();
        error = "hydraulic: buffer allocation failed";
        pool->release();
        return false;
    }

    MTL::CommandBuffer* cb = ctx.queue()->commandBuffer();

    // Zero the dynamic state buffers.
    MTL::BlitCommandEncoder* blit = cb->blitCommandEncoder();
    blit->fillBuffer(water, NS::Range(0, n * sizeof(float)), 0);
    blit->fillBuffer(flux, NS::Range(0, n * sizeof(float) * 4), 0);
    blit->fillBuffer(vel, NS::Range(0, n * sizeof(float) * 2), 0);
    blit->fillBuffer(sedA, NS::Range(0, n * sizeof(float)), 0);
    blit->fillBuffer(sedB, NS::Range(0, n * sizeof(float)), 0);
    blit->endEncoding();

    MTL::ComputeCommandEncoder* enc = cb->computeCommandEncoder();
    const MTL::Size grid(W, H, 1);
    auto disp = [&](MTL::ComputePipelineState* p) {
        const NS::UInteger tw = p->threadExecutionWidth();
        const NS::UInteger th =
            std::max<NS::UInteger>(1, p->maxTotalThreadsPerThreadgroup() / tw);
        enc->setComputePipelineState(p);
        enc->dispatchThreads(grid, MTL::Size(tw, th, 1));
        enc->memoryBarrier(MTL::BarrierScopeBuffers);
    };

    // init: terrainA = input * heightScale
    enc->setBuffer(in->buffer(), 0, 8);
    enc->setBuffer(terrainA, 0, 0);
    enc->setBytes(&P, sizeof(P), 7);
    disp(pso("hydro_init"));

    MTL::Buffer* tSrc = terrainA;
    MTL::Buffer* tDst = terrainB;
    for (int it = 0; it < iterations; ++it) {
        // rain
        enc->setBuffer(water, 0, 2);
        enc->setBytes(&P, sizeof(P), 7);
        disp(pso("hydro_rain"));
        // flux
        enc->setBuffer(tSrc, 0, 0);
        enc->setBuffer(water, 0, 2);
        enc->setBuffer(flux, 0, 3);
        disp(pso("hydro_flux"));
        // water + velocity
        enc->setBuffer(water, 0, 2);
        enc->setBuffer(flux, 0, 3);
        enc->setBuffer(vel, 0, 4);
        disp(pso("hydro_water"));
        // erode/deposit: tSrc->tDst, sedA->sedB
        enc->setBuffer(tSrc, 0, 0);
        enc->setBuffer(tDst, 0, 1);
        enc->setBuffer(water, 0, 2);
        enc->setBuffer(vel, 0, 4);
        enc->setBuffer(sedA, 0, 5);
        enc->setBuffer(sedB, 0, 6);
        disp(pso("hydro_erode"));
        // advect sediment: sedB->sedA
        enc->setBuffer(sedB, 0, 5);
        enc->setBuffer(sedA, 0, 6);
        enc->setBuffer(vel, 0, 4);
        disp(pso("hydro_advect"));
        // evaporate
        enc->setBuffer(water, 0, 2);
        disp(pso("hydro_evap"));

        std::swap(tSrc, tDst);  // tSrc now holds the latest terrain
    }

    // finish: out = tSrc / heightScale
    enc->setBuffer(tSrc, 0, 0);
    enc->setBuffer(out.buffer(), 0, 9);
    enc->setBytes(&P, sizeof(P), 7);
    disp(pso("hydro_finish"));

    enc->endEncoding();
    cb->commit();
    cb->waitUntilCompleted();

    const bool ok = cb->status() == MTL::CommandBufferStatusCompleted;
    if (!ok) {
        error = "hydraulic: command buffer did not complete (status " +
                std::to_string(static_cast<int>(cb->status())) + ")";
    }
    for (auto* b : owned) b->release();
    pool->release();
    return ok;
}

} // namespace theia
