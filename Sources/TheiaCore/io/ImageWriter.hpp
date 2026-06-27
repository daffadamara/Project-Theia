#pragma once
//
// Heightmap export. PRIVATE header.
//   - PFM: 32-bit float, lossless — the real data export.
//   - PNG: 8-bit grayscale (via stb_image_write) — a quick, universally
//     viewable preview. Values are normalized from [minV,maxV] to [0,255].
//
#include <cstdint>
#include <string>

namespace theia {

// Write a single-channel 32-bit float PFM. `data` is row-major, top row first;
// PFM stores bottom row first, so rows are flipped on write.
bool writePFM(const char* path, const float* data,
              std::uint32_t width, std::uint32_t height, std::string& error);

// Write an 8-bit grayscale PNG, normalizing [minV,maxV] -> [0,255].
bool writePNG8(const char* path, const float* data,
               std::uint32_t width, std::uint32_t height,
               float minV, float maxV, std::string& error);

// Write a 16-bit grayscale PNG, normalizing [minV,maxV] -> [0,65535]. Avoids the
// banding of 8-bit for heightmaps. Self-contained (stored-block DEFLATE), no
// external compression dependency.
bool writePNG16(const char* path, const float* data,
                std::uint32_t width, std::uint32_t height,
                float minV, float maxV, std::string& error);

} // namespace theia
