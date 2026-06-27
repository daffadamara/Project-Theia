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

} // namespace theia
