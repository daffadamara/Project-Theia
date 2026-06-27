#pragma once
//
// Heightfield — a width x height grid of float32 heights backed by a Metal
// buffer with shared storage (zero-copy CPU<->GPU on Apple Silicon). This is the
// value that flows between graph nodes. PRIVATE header (uses Metal internally);
// MTL::Buffer is forward-declared so this header stays metal-cpp-free.
//
#include <cstddef>
#include <cstdint>

namespace MTL {
class Buffer;
}

namespace theia {

class GPUContext;

class Heightfield {
public:
    // Allocates a w*h float buffer (shared storage) via the context's device.
    Heightfield(GPUContext& ctx, std::uint32_t width, std::uint32_t height);
    ~Heightfield();

    Heightfield(Heightfield&&) noexcept;
    Heightfield& operator=(Heightfield&&) noexcept;
    Heightfield(const Heightfield&) = delete;
    Heightfield& operator=(const Heightfield&) = delete;

    std::uint32_t width() const { return width_; }
    std::uint32_t height() const { return height_; }
    std::size_t count() const { return std::size_t(width_) * height_; }

    bool valid() const { return buffer_ != nullptr; }

    MTL::Buffer* buffer() const { return buffer_; }

    // CPU view of the shared buffer (valid after GPU work has completed).
    float* data();
    const float* data() const;

    // Compute min/max/mean/variance over all texels (CPU scan). Also serves as
    // a non-degeneracy check (variance > 0 means real structure).
    void stats(float& minV, float& maxV, double& mean, double& variance) const;

private:
    std::uint32_t width_ = 0;
    std::uint32_t height_ = 0;
    MTL::Buffer* buffer_ = nullptr;  // owned
};

} // namespace theia
