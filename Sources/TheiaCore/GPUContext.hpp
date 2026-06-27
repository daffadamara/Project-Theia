#pragma once
//
// GPUContext — owns the Metal device + command queue and a cache of compute
// pipeline states compiled at runtime from MSL source. This is a PRIVATE header
// (it lives outside include/, so it is not exported to Swift). It intentionally
// does not include metal-cpp; the device/queue/PSO handles are hidden behind a
// pimpl so this header stays dependency-light.
//
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

// Forward declarations so this header stays free of metal-cpp.
namespace MTL {
class Device;
class CommandQueue;
class ComputePipelineState;
} // namespace MTL

namespace theia {

class GPUContext {
public:
    // Creates the system-default Metal device + a command queue.
    // Returns nullptr on failure and writes a message into `error`.
    static std::unique_ptr<GPUContext> create(std::string& error);
    ~GPUContext();

    GPUContext(const GPUContext&) = delete;
    GPUContext& operator=(const GPUContext&) = delete;

    std::string deviceName() const;

    MTL::Device* device() const;
    MTL::CommandQueue* queue() const;

    // Compile a compute pipeline from MSL `source` (entry point `fnName`) and
    // cache it under `key`. Subsequent calls with the same key return the cached
    // pipeline without recompiling. Returns nullptr + sets `error` on failure.
    MTL::ComputePipelineState* pipeline(const std::string& key,
                                        const char* source,
                                        const char* fnName,
                                        std::string& error);

    // M0: dispatch the "fill" kernel over `count` floats, writing `value` to
    // each, then read the buffer back into `out`. Returns false + sets `error`
    // on any failure.
    bool runFill(std::uint32_t count, float value,
                 std::vector<float>& out, std::string& error);

private:
    GPUContext();
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace theia
