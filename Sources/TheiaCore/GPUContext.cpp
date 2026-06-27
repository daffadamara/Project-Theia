#include "GPUContext.hpp"

#include <Foundation/Foundation.hpp>
#include <Metal/Metal.hpp>

#include <algorithm>
#include <unordered_map>

#include "kernels/Kernels.metal.hpp"

namespace theia {

namespace {
// Convert an NS::String* to std::string (empty if null).
std::string nsToStd(const NS::String* s) {
    if (!s) return {};
    const char* c = s->utf8String();
    return c ? std::string(c) : std::string{};
}

// Describe an NS::Error* for diagnostics.
std::string errString(NS::Error* err) {
    if (!err) return "unknown error";
    return nsToStd(err->localizedDescription());
}
} // namespace

struct GPUContext::Impl {
    MTL::Device* device = nullptr;
    MTL::CommandQueue* queue = nullptr;
    std::unordered_map<std::string, MTL::ComputePipelineState*> pipelines;

    ~Impl() {
        for (auto& kv : pipelines) {
            if (kv.second) kv.second->release();
        }
        if (queue) queue->release();
        if (device) device->release();
    }
};

GPUContext::GPUContext() : impl_(std::make_unique<Impl>()) {}
GPUContext::~GPUContext() = default;

std::unique_ptr<GPUContext> GPUContext::create(std::string& error) {
    NS::AutoreleasePool* pool = NS::AutoreleasePool::alloc()->init();

    MTL::Device* device = MTL::CreateSystemDefaultDevice();
    if (!device) {
        error = "no Metal device available (MTL::CreateSystemDefaultDevice returned null)";
        pool->release();
        return nullptr;
    }
    MTL::CommandQueue* queue = device->newCommandQueue();
    if (!queue) {
        error = "failed to create Metal command queue";
        device->release();
        pool->release();
        return nullptr;
    }

    // Can't use make_unique with a private constructor; construct directly.
    std::unique_ptr<GPUContext> ctx(new GPUContext());
    ctx->impl_->device = device;  // ownership transferred (CreateSystemDefaultDevice is +1)
    ctx->impl_->queue = queue;    // newCommandQueue is +1

    pool->release();
    return ctx;
}

std::string GPUContext::deviceName() const {
    if (!impl_->device) return {};
    return nsToStd(impl_->device->name());
}

MTL::Device* GPUContext::device() const { return impl_->device; }
MTL::CommandQueue* GPUContext::queue() const { return impl_->queue; }

MTL::ComputePipelineState* GPUContext::pipeline(const std::string& key,
                                                const char* source,
                                                const char* fnName,
                                                std::string& error) {
    auto it = impl_->pipelines.find(key);
    if (it != impl_->pipelines.end()) return it->second;

    NS::AutoreleasePool* pool = NS::AutoreleasePool::alloc()->init();
    NS::Error* nsErr = nullptr;
    NS::String* src = NS::String::string(source, NS::UTF8StringEncoding);
    MTL::Library* lib = impl_->device->newLibrary(src, nullptr, &nsErr);
    if (!lib) {
        error = "kernel '" + key + "' compile failed: " + errString(nsErr);
        pool->release();
        return nullptr;
    }
    MTL::Function* fn =
        lib->newFunction(NS::String::string(fnName, NS::UTF8StringEncoding));
    if (!fn) {
        error = "entry point '" + std::string(fnName) + "' not found in '" + key + "'";
        lib->release();
        pool->release();
        return nullptr;
    }
    MTL::ComputePipelineState* pso = impl_->device->newComputePipelineState(fn, &nsErr);
    fn->release();
    lib->release();
    if (!pso) {
        error = "pipeline '" + key + "' creation failed: " + errString(nsErr);
        pool->release();
        return nullptr;
    }
    impl_->pipelines.emplace(key, pso);  // cache owns the PSO
    pool->release();
    return pso;
}

bool GPUContext::dispatch2D(
    const std::string& key, const char* source, const char* fnName,
    std::uint32_t width, std::uint32_t height,
    const std::function<void(MTL::ComputeCommandEncoder*)>& bindArgs,
    std::string& error) {
    if (width == 0 || height == 0) {
        error = "dispatch2D: zero-sized grid";
        return false;
    }
    MTL::ComputePipelineState* pso = pipeline(key, source, fnName, error);
    if (!pso) return false;

    NS::AutoreleasePool* pool = NS::AutoreleasePool::alloc()->init();

    MTL::CommandBuffer* cb = impl_->queue->commandBuffer();
    MTL::ComputeCommandEncoder* enc = cb->computeCommandEncoder();
    enc->setComputePipelineState(pso);
    bindArgs(enc);

    // Non-uniform threadgroups (supported on Apple GPUs): pick a 2D group from
    // the pipeline's execution width / max threads.
    const NS::UInteger w = pso->threadExecutionWidth();
    const NS::UInteger h =
        std::max<NS::UInteger>(1, pso->maxTotalThreadsPerThreadgroup() / w);
    MTL::Size grid(width, height, 1);
    MTL::Size tg(w, h, 1);
    enc->dispatchThreads(grid, tg);
    enc->endEncoding();
    cb->commit();
    cb->waitUntilCompleted();

    const bool ok = cb->status() == MTL::CommandBufferStatusCompleted;
    if (!ok) {
        error = "kernel '" + key + "' did not complete (status " +
                std::to_string(static_cast<int>(cb->status())) + ")";
    }
    pool->release();
    return ok;
}

bool GPUContext::runFill(std::uint32_t count, float value,
                         std::vector<float>& out, std::string& error) {
    if (count == 0) {
        out.clear();
        return true;
    }

    MTL::Device* device = impl_->device;
    bool ok = false;

    // Compile-and-cache the fill kernel (runtime MSL compilation).
    MTL::ComputePipelineState* pso = pipeline("fill", kernels::kFill, "fill", error);
    if (!pso) return false;

    NS::AutoreleasePool* pool = NS::AutoreleasePool::alloc()->init();

    // --- Allocate the output buffer (shared storage = zero-copy on Apple GPUs) -
    const std::size_t bytes = std::size_t(count) * sizeof(float);
    MTL::Buffer* outBuf = device->newBuffer(bytes, MTL::ResourceStorageModeShared);
    if (!outBuf) {
        error = "failed to allocate output buffer";
    } else {
        // --- Encode & dispatch ------------------------------------------------
        MTL::CommandBuffer* cb = impl_->queue->commandBuffer();
        MTL::ComputeCommandEncoder* enc = cb->computeCommandEncoder();
        enc->setComputePipelineState(pso);
        enc->setBuffer(outBuf, 0, 0);
        enc->setBytes(&value, sizeof(float), 1);
        enc->setBytes(&count, sizeof(std::uint32_t), 2);

        const NS::UInteger maxThreads = pso->maxTotalThreadsPerThreadgroup();
        const NS::UInteger tgWidth = std::min<NS::UInteger>(maxThreads, count);
        MTL::Size grid(count, 1, 1);
        MTL::Size threadgroup(tgWidth, 1, 1);
        enc->dispatchThreads(grid, threadgroup);  // non-uniform groups (Apple GPU)
        enc->endEncoding();
        cb->commit();
        cb->waitUntilCompleted();

        if (cb->status() == MTL::CommandBufferStatusCompleted) {
            const float* p = static_cast<const float*>(outBuf->contents());
            out.assign(p, p + count);
            ok = true;
        } else {
            error = "command buffer did not complete (status " +
                    std::to_string(static_cast<int>(cb->status())) + ")";
        }
        outBuf->release();
    }

    pool->release();  // pso is owned by the pipeline cache; do not release here
    return ok;
}

} // namespace theia
