#include "Heightfield.hpp"

#include <Metal/Metal.hpp>
#include <utility>

#include "GPUContext.hpp"

namespace theia {

Heightfield::Heightfield(GPUContext& ctx, std::uint32_t width, std::uint32_t height)
    : width_(width), height_(height) {
    const std::size_t bytes = std::size_t(width) * height * sizeof(float);
    if (bytes > 0 && ctx.device()) {
        buffer_ = ctx.device()->newBuffer(bytes, MTL::ResourceStorageModeShared);
    }
}

Heightfield::~Heightfield() {
    if (buffer_) buffer_->release();
}

Heightfield::Heightfield(Heightfield&& other) noexcept
    : width_(other.width_), height_(other.height_), buffer_(other.buffer_) {
    other.buffer_ = nullptr;
    other.width_ = 0;
    other.height_ = 0;
}

Heightfield& Heightfield::operator=(Heightfield&& other) noexcept {
    if (this != &other) {
        if (buffer_) buffer_->release();
        width_ = other.width_;
        height_ = other.height_;
        buffer_ = other.buffer_;
        other.buffer_ = nullptr;
        other.width_ = 0;
        other.height_ = 0;
    }
    return *this;
}

float* Heightfield::data() {
    return buffer_ ? static_cast<float*>(buffer_->contents()) : nullptr;
}

const float* Heightfield::data() const {
    return buffer_ ? static_cast<const float*>(buffer_->contents()) : nullptr;
}

void Heightfield::stats(float& minV, float& maxV, double& mean,
                        double& variance) const {
    const float* d = data();
    const std::size_t n = count();
    if (!d || n == 0) {
        minV = maxV = 0.0f;
        mean = variance = 0.0;
        return;
    }
    float mn = d[0], mx = d[0];
    double sum = 0.0;
    for (std::size_t i = 0; i < n; ++i) {
        const float v = d[i];
        if (v < mn) mn = v;
        if (v > mx) mx = v;
        sum += v;
    }
    const double m = sum / double(n);
    double var = 0.0;
    for (std::size_t i = 0; i < n; ++i) {
        const double dv = double(d[i]) - m;
        var += dv * dv;
    }
    minV = mn;
    maxV = mx;
    mean = m;
    variance = var / double(n);
}

} // namespace theia
