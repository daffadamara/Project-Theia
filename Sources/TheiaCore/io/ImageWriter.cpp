#include "io/ImageWriter.hpp"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"  // stb uses sprintf
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"
#pragma clang diagnostic pop

#include <cstdio>
#include <vector>

namespace theia {

bool writePFM(const char* path, const float* data,
              std::uint32_t width, std::uint32_t height, std::string& error) {
    if (!data || width == 0 || height == 0) {
        error = "writePFM: empty image";
        return false;
    }
    FILE* f = std::fopen(path, "wb");
    if (!f) {
        error = std::string("writePFM: cannot open ") + path;
        return false;
    }
    // Grayscale PFM header; scale -1.0 => little-endian samples (x86/ARM native).
    std::fprintf(f, "Pf\n%u %u\n-1.0\n", width, height);

    // PFM stores rows bottom-to-top; our data is top-to-bottom. Flip on write.
    bool ok = true;
    for (std::uint32_t y = 0; y < height && ok; ++y) {
        const float* row = data + std::size_t(height - 1 - y) * width;
        ok = std::fwrite(row, sizeof(float), width, f) == width;
    }
    std::fclose(f);
    if (!ok) error = "writePFM: short write";
    return ok;
}

bool writePNG8(const char* path, const float* data,
               std::uint32_t width, std::uint32_t height,
               float minV, float maxV, std::string& error) {
    if (!data || width == 0 || height == 0) {
        error = "writePNG8: empty image";
        return false;
    }
    const float range = (maxV > minV) ? (maxV - minV) : 1.0f;
    std::vector<unsigned char> px(std::size_t(width) * height);
    for (std::size_t i = 0; i < px.size(); ++i) {
        float t = (data[i] - minV) / range;
        t = t < 0.0f ? 0.0f : (t > 1.0f ? 1.0f : t);
        px[i] = static_cast<unsigned char>(t * 255.0f + 0.5f);
    }
    // stb writes top row first, matching our row-major layout.
    int rc = stbi_write_png(path, int(width), int(height), 1,
                            px.data(), int(width));
    if (rc == 0) {
        error = std::string("writePNG8: stbi_write_png failed for ") + path;
        return false;
    }
    return true;
}

} // namespace theia
