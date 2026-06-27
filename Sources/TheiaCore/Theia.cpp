#include "Theia/Theia.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>

#include "GPUContext.hpp"
#include "Heightfield.hpp"
#include "io/ImageWriter.hpp"
#include "nodes/PerlinNoiseNode.hpp"

namespace theia {

namespace {
std::size_t copyOut(const std::string& s, char* out, std::size_t cap) {
    if (out && cap > 0) {
        const std::size_t n = std::min(cap - 1, s.size());
        std::memcpy(out, s.data(), n);
        out[n] = '\0';
    }
    return s.size();
}
} // namespace

std::size_t smoke_device_name(const SmokeResult& r, char* out, std::size_t cap) {
    return copyOut(r.deviceName, out, cap);
}

std::size_t smoke_error(const SmokeResult& r, char* out, std::size_t cap) {
    return copyOut(r.error, out, cap);
}

std::size_t generate_error(const GenerateResult& r, char* out, std::size_t cap) {
    return copyOut(r.error, out, cap);
}

GenerateResult generate_perlin(const PerlinParams& p,
                               const char* pngPath, const char* pfmPath) {
    GenerateResult r;
    r.width = p.width;
    r.height = p.height;

    if (p.width == 0 || p.height == 0) {
        r.error = "width and height must be > 0";
        return r;
    }

    std::string error;
    auto ctx = GPUContext::create(error);
    if (!ctx) {
        r.error = error;
        return r;
    }

    Heightfield hf(*ctx, p.width, p.height);
    if (!hf.valid()) {
        r.error = "failed to allocate heightfield buffer";
        return r;
    }

    PerlinSettings s;
    s.seed = p.seed;
    s.octaves = p.octaves;
    s.frequency = p.frequency;
    s.lacunarity = p.lacunarity;
    s.gain = p.gain;
    if (!generatePerlin(*ctx, hf, s, error)) {
        r.error = error;
        return r;
    }

    // --- Stats (also our determinism / non-degeneracy check) -----------------
    const float* d = hf.data();
    const std::size_t n = hf.count();
    float mn = d[0], mx = d[0];
    double sum = 0.0;
    for (std::size_t i = 0; i < n; ++i) {
        const float v = d[i];
        mn = std::min(mn, v);
        mx = std::max(mx, v);
        sum += v;
    }
    const double mean = sum / double(n);
    double var = 0.0;
    for (std::size_t i = 0; i < n; ++i) {
        const double dv = double(d[i]) - mean;
        var += dv * dv;
    }
    var /= double(n);

    r.minHeight = mn;
    r.maxHeight = mx;
    r.mean = mean;
    r.variance = var;

    // --- Export --------------------------------------------------------------
    if (pfmPath && pfmPath[0]) {
        if (!writePFM(pfmPath, d, p.width, p.height, error)) {
            r.error = error;
            return r;
        }
    }
    if (pngPath && pngPath[0]) {
        if (!writePNG8(pngPath, d, p.width, p.height, mn, mx, error)) {
            r.error = error;
            return r;
        }
    }

    r.ok = true;
    return r;
}

SmokeResult gpu_smoke_fill(std::uint32_t count, float value) {
    SmokeResult r;
    r.count = count;

    std::string error;
    auto ctx = GPUContext::create(error);
    if (!ctx) {
        r.error = error;
        return r;
    }
    r.deviceName = ctx->deviceName();

    std::vector<float> out;
    if (!ctx->runFill(count, value, out, error)) {
        r.error = error;
        return r;
    }

    if (out.size() != count) {
        r.error = "unexpected result size";
        return r;
    }

    if (count > 0) {
        r.first = out.front();
        r.last = out.back();
    }
    r.allMatch = true;
    for (float v : out) {
        if (v != value) { r.allMatch = false; break; }
    }
    r.ok = r.allMatch;
    return r;
}

} // namespace theia
