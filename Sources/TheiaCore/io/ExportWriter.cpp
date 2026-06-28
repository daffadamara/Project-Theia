#include "io/ExportWriter.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

#include "io/ImageWriter.hpp"

namespace theia {
namespace {

struct Vec3 {
    float x = 0.0f;
    float y = 1.0f;
    float z = 0.0f;
};

float clamp01(float v) {
    return std::min(1.0f, std::max(0.0f, v));
}

Vec3 normalAt(const float* data, std::uint32_t width, std::uint32_t height,
              std::uint32_t x, std::uint32_t y, float verticalScale) {
    const std::uint32_t xl = x > 0 ? x - 1 : x;
    const std::uint32_t xr = x + 1 < width ? x + 1 : x;
    const std::uint32_t yd = y > 0 ? y - 1 : y;
    const std::uint32_t yu = y + 1 < height ? y + 1 : y;
    const float hl = data[std::size_t(y) * width + xl];
    const float hr = data[std::size_t(y) * width + xr];
    const float hd = data[std::size_t(yd) * width + x];
    const float hu = data[std::size_t(yu) * width + x];
    const float sx = width > 1 ? 2.0f / float(width - 1) : 1.0f;
    const float sz = height > 1 ? 2.0f / float(height - 1) : 1.0f;
    const float xSpan = std::max(1u, xr - xl);
    const float zSpan = std::max(1u, yu - yd);
    const float dx = (hr - hl) * verticalScale / (float(xSpan) * sx);
    const float dz = (hu - hd) * verticalScale / (float(zSpan) * sz);
    Vec3 n{-dx, 1.0f, -dz};
    const float len = std::sqrt(n.x * n.x + n.y * n.y + n.z * n.z);
    if (len > 0.0f) {
        n.x /= len;
        n.y /= len;
        n.z /= len;
    }
    return n;
}

bool validateRaster(const char* path, const float* data, std::uint32_t width,
                    std::uint32_t height, std::string& error,
                    const char* label) {
    if (!path || !path[0]) {
        error = std::string(label) + ": empty path";
        return false;
    }
    if (!data || width < 2 || height < 2) {
        error = std::string(label) + ": need at least a 2x2 heightfield";
        return false;
    }
    return true;
}

} // namespace

bool writeNormalPNG(const char* path, const float* data,
                    std::uint32_t width, std::uint32_t height,
                    float verticalScale, std::string& error) {
    if (!validateRaster(path, data, width, height, error, "writeNormalPNG")) {
        return false;
    }

    std::vector<unsigned char> rgb(std::size_t(width) * height * 3);
    for (std::uint32_t y = 0; y < height; ++y) {
        for (std::uint32_t x = 0; x < width; ++x) {
            const Vec3 n = normalAt(data, width, height, x, y, verticalScale);
            const std::size_t i = (std::size_t(y) * width + x) * 3;
            rgb[i + 0] = static_cast<unsigned char>(clamp01(n.x * 0.5f + 0.5f) * 255.0f + 0.5f);
            rgb[i + 1] = static_cast<unsigned char>(clamp01(n.y * 0.5f + 0.5f) * 255.0f + 0.5f);
            rgb[i + 2] = static_cast<unsigned char>(clamp01(n.z * 0.5f + 0.5f) * 255.0f + 0.5f);
        }
    }
    return writePNG8RGB(path, rgb.data(), width, height, error);
}

bool writeSlopePNG16(const char* path, const float* data,
                     std::uint32_t width, std::uint32_t height,
                     float verticalScale, std::string& error) {
    if (!validateRaster(path, data, width, height, error, "writeSlopePNG16")) {
        return false;
    }

    // Like GDAL gdaldem/GRASS slope-aspect tools, derive slope angle from local
    // terrain gradient. Store degrees normalized over 0..90 for a PNG16 map.
    std::vector<float> slope(std::size_t(width) * height);
    for (std::uint32_t y = 0; y < height; ++y) {
        for (std::uint32_t x = 0; x < width; ++x) {
            const Vec3 n = normalAt(data, width, height, x, y, verticalScale);
            const float ny = std::min(1.0f, std::max(0.0f, n.y));
            const float deg = std::acos(ny) * 57.2957795131f;
            slope[std::size_t(y) * width + x] = std::min(90.0f, std::max(0.0f, deg));
        }
    }
    return writePNG16(path, slope.data(), width, height, 0.0f, 90.0f, error);
}

bool writeOBJ(const char* path, const float* data,
              std::uint32_t width, std::uint32_t height,
              float verticalScale, std::uint32_t stride,
              std::string& error) {
    if (!validateRaster(path, data, width, height, error, "writeOBJ")) {
        return false;
    }
    if (stride == 0) {
        error = "writeOBJ: mesh stride must be > 0";
        return false;
    }

    std::vector<std::uint32_t> xs;
    std::vector<std::uint32_t> ys;
    for (std::uint32_t x = 0; x < width; x += stride) xs.push_back(x);
    for (std::uint32_t y = 0; y < height; y += stride) ys.push_back(y);
    if (xs.back() != width - 1) xs.push_back(width - 1);
    if (ys.back() != height - 1) ys.push_back(height - 1);
    if (xs.size() < 2 || ys.size() < 2) {
        error = "writeOBJ: mesh stride leaves fewer than 2 samples per axis";
        return false;
    }

    FILE* f = std::fopen(path, "wb");
    if (!f) {
        error = std::string("writeOBJ: cannot open ") + path;
        return false;
    }

    bool ok = true;
    ok &= std::fprintf(f, "# Theia terrain export\n") > 0;
    ok &= std::fprintf(f, "# coordinates: +Y up, X/Z in [-1,1]\n") > 0;

    for (std::uint32_t y : ys) {
        const float z = (float(y) / float(height - 1)) * 2.0f - 1.0f;
        for (std::uint32_t x : xs) {
            const float vx = (float(x) / float(width - 1)) * 2.0f - 1.0f;
            const float vy = data[std::size_t(y) * width + x] * verticalScale;
            ok &= std::fprintf(f, "v %.9g %.9g %.9g\n", vx, vy, z) > 0;
        }
    }
    for (std::uint32_t y : ys) {
        const float v = float(y) / float(height - 1);
        for (std::uint32_t x : xs) {
            const float u = float(x) / float(width - 1);
            ok &= std::fprintf(f, "vt %.9g %.9g\n", u, v) > 0;
        }
    }
    for (std::uint32_t y : ys) {
        for (std::uint32_t x : xs) {
            const Vec3 n = normalAt(data, width, height, x, y, verticalScale);
            ok &= std::fprintf(f, "vn %.9g %.9g %.9g\n", n.x, n.y, n.z) > 0;
        }
    }

    const std::size_t row = xs.size();
    for (std::size_t y = 0; y + 1 < ys.size(); ++y) {
        for (std::size_t x = 0; x + 1 < xs.size(); ++x) {
            const std::uint32_t i0 = std::uint32_t(y * row + x + 1);
            const std::uint32_t i1 = std::uint32_t((y + 1) * row + x + 1);
            const std::uint32_t i2 = std::uint32_t(y * row + x + 2);
            const std::uint32_t i3 = std::uint32_t((y + 1) * row + x + 2);
            // Counter-clockwise when viewed from above, matching the viewer's
            // one-sided terrain mesh winding.
            ok &= std::fprintf(f, "f %u/%u/%u %u/%u/%u %u/%u/%u\n",
                               i0, i0, i0, i1, i1, i1, i2, i2, i2) > 0;
            ok &= std::fprintf(f, "f %u/%u/%u %u/%u/%u %u/%u/%u\n",
                               i2, i2, i2, i1, i1, i1, i3, i3, i3) > 0;
        }
    }

    std::fclose(f);
    if (!ok) {
        error = "writeOBJ: short write";
        return false;
    }
    return true;
}

} // namespace theia
