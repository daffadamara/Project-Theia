#pragma once

#include <cstdint>
#include <string>

namespace theia {

bool writeNormalPNG(const char* path, const float* data,
                    std::uint32_t width, std::uint32_t height,
                    float verticalScale, std::string& error);

bool writeSlopePNG16(const char* path, const float* data,
                     std::uint32_t width, std::uint32_t height,
                     float verticalScale, std::string& error);

bool writeOBJ(const char* path, const float* data,
              std::uint32_t width, std::uint32_t height,
              float verticalScale, std::uint32_t stride,
              std::string& error);

} // namespace theia
