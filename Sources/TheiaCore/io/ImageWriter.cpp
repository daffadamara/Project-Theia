#include "io/ImageWriter.hpp"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"  // stb uses sprintf
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"
#pragma clang diagnostic pop

#include <cstdint>
#include <cstdio>
#include <vector>

namespace theia {

namespace {
// --- minimal PNG-16 support (CRC32 + Adler32 + stored-block DEFLATE) ---------
std::uint32_t crc32Of(const unsigned char* p, std::size_t n, std::uint32_t crc) {
    crc = ~crc;
    for (std::size_t i = 0; i < n; ++i) {
        crc ^= p[i];
        for (int k = 0; k < 8; ++k)
            crc = (crc >> 1) ^ (0xEDB88320u & (~(crc & 1u) + 1u));
    }
    return ~crc;
}

void putU32BE(std::vector<unsigned char>& v, std::uint32_t x) {
    v.push_back((x >> 24) & 0xFF);
    v.push_back((x >> 16) & 0xFF);
    v.push_back((x >> 8) & 0xFF);
    v.push_back(x & 0xFF);
}

void writeChunk(std::vector<unsigned char>& out, const char type[4],
                const std::vector<unsigned char>& data) {
    putU32BE(out, static_cast<std::uint32_t>(data.size()));
    const std::size_t start = out.size();
    out.insert(out.end(), type, type + 4);
    out.insert(out.end(), data.begin(), data.end());
    const std::uint32_t crc = crc32Of(out.data() + start, 4 + data.size(), 0);
    putU32BE(out, crc);
}

// zlib stream wrapping raw bytes as uncompressed (stored) DEFLATE blocks.
std::vector<unsigned char> zlibStore(const std::vector<unsigned char>& raw) {
    std::vector<unsigned char> z;
    z.push_back(0x78);
    z.push_back(0x01);  // CMF/FLG: deflate, (0x7801 % 31 == 0)
    std::size_t pos = 0, n = raw.size();
    while (pos < n) {
        std::size_t len = std::min<std::size_t>(65535, n - pos);
        z.push_back((pos + len == n) ? 1 : 0);  // BFINAL, BTYPE=00 (stored)
        z.push_back(len & 0xFF);
        z.push_back((len >> 8) & 0xFF);
        std::uint16_t nlen = static_cast<std::uint16_t>(~len);
        z.push_back(nlen & 0xFF);
        z.push_back((nlen >> 8) & 0xFF);
        z.insert(z.end(), raw.begin() + pos, raw.begin() + pos + len);
        pos += len;
    }
    // Adler-32 of the raw data, big-endian.
    std::uint32_t a = 1, b = 0;
    for (std::size_t i = 0; i < n; ++i) {
        a = (a + raw[i]) % 65521;
        b = (b + a) % 65521;
    }
    putU32BE(z, (b << 16) | a);
    return z;
}
} // namespace

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

bool writePNG16(const char* path, const float* data,
                std::uint32_t width, std::uint32_t height,
                float minV, float maxV, std::string& error) {
    if (!data || width == 0 || height == 0) {
        error = "writePNG16: empty image";
        return false;
    }
    const float range = (maxV > minV) ? (maxV - minV) : 1.0f;

    // Filtered scanlines: each row = filter byte (0) + width big-endian uint16.
    std::vector<unsigned char> raw;
    raw.reserve(std::size_t(height) * (1 + 2 * std::size_t(width)));
    for (std::uint32_t y = 0; y < height; ++y) {
        raw.push_back(0);  // filter: none
        const float* row = data + std::size_t(y) * width;
        for (std::uint32_t x = 0; x < width; ++x) {
            float t = (row[x] - minV) / range;
            t = t < 0.0f ? 0.0f : (t > 1.0f ? 1.0f : t);
            std::uint16_t v = static_cast<std::uint16_t>(t * 65535.0f + 0.5f);
            raw.push_back((v >> 8) & 0xFF);
            raw.push_back(v & 0xFF);
        }
    }

    std::vector<unsigned char> png = {0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A};

    std::vector<unsigned char> ihdr;
    putU32BE(ihdr, width);
    putU32BE(ihdr, height);
    ihdr.push_back(16);  // bit depth
    ihdr.push_back(0);   // color type: grayscale
    ihdr.push_back(0);   // compression
    ihdr.push_back(0);   // filter
    ihdr.push_back(0);   // interlace
    writeChunk(png, "IHDR", ihdr);
    writeChunk(png, "IDAT", zlibStore(raw));
    writeChunk(png, "IEND", {});

    FILE* f = std::fopen(path, "wb");
    if (!f) {
        error = std::string("writePNG16: cannot open ") + path;
        return false;
    }
    const bool ok = std::fwrite(png.data(), 1, png.size(), f) == png.size();
    std::fclose(f);
    if (!ok) error = "writePNG16: short write";
    return ok;
}

bool writeR16(const char* path, const float* data,
              std::uint32_t width, std::uint32_t height,
              float minV, float maxV, std::string& error) {
    if (!data || width == 0 || height == 0) {
        error = "writeR16: empty image";
        return false;
    }
    FILE* f = std::fopen(path, "wb");
    if (!f) {
        error = std::string("writeR16: cannot open ") + path;
        return false;
    }

    const float range = (maxV > minV) ? (maxV - minV) : 1.0f;
    std::vector<unsigned char> bytes(std::size_t(width) * height * 2);
    for (std::size_t i = 0, j = 0; i < std::size_t(width) * height; ++i, j += 2) {
        float t = (data[i] - minV) / range;
        t = t < 0.0f ? 0.0f : (t > 1.0f ? 1.0f : t);
        const std::uint16_t v = static_cast<std::uint16_t>(t * 65535.0f + 0.5f);
        bytes[j] = static_cast<unsigned char>(v & 0xFF);
        bytes[j + 1] = static_cast<unsigned char>((v >> 8) & 0xFF);
    }

    const bool ok = std::fwrite(bytes.data(), 1, bytes.size(), f) == bytes.size();
    std::fclose(f);
    if (!ok) error = "writeR16: short write";
    return ok;
}

bool writePNG8RGB(const char* path, const unsigned char* rgb,
                  std::uint32_t width, std::uint32_t height,
                  std::string& error) {
    if (!rgb || width == 0 || height == 0) {
        error = "writePNG8RGB: empty image";
        return false;
    }
    const int stride = int(width) * 3;
    const int rc = stbi_write_png(path, int(width), int(height), 3, rgb, stride);
    if (rc == 0) {
        error = std::string("writePNG8RGB: stbi_write_png failed for ") + path;
        return false;
    }
    return true;
}

bool writePNG8RGBA(const char* path, const unsigned char* rgba,
                   std::uint32_t width, std::uint32_t height,
                   std::string& error) {
    if (!rgba || width == 0 || height == 0) {
        error = "writePNG8RGBA: empty image";
        return false;
    }
    const int stride = int(width) * 4;
    const int rc = stbi_write_png(path, int(width), int(height), 4, rgba, stride);
    if (rc == 0) {
        error = std::string("writePNG8RGBA: stbi_write_png failed for ") + path;
        return false;
    }
    return true;
}

} // namespace theia
