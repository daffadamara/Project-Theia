#pragma once
//
// Theia — public C++ API surface.
//
// IMPORTANT: everything reachable from this header must be Swift/C++-interop
// safe. Do NOT include metal-cpp or expose Metal types here — those are
// encapsulated inside the .cpp implementation. Keep this header to standard
// library types and plain structs so the Swift shell can import it cleanly.
//
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace theia {

// Result of the M0 GPU smoke test: compile a tiny kernel at runtime, run it,
// and read the result back. Proves the metal-cpp + runtime-MSL + Swift/C++
// interop toolchain works end-to-end without full Xcode.
struct SmokeResult {
    bool ok = false;            // true if the kernel ran and results verified
    std::string deviceName;     // the Metal device that ran the work
    std::string error;          // populated when ok == false
    std::uint32_t count = 0;    // number of elements processed
    float first = 0.0f;         // out[0]
    float last = 0.0f;          // out[count-1]
    bool allMatch = false;      // every element equals the requested value
};

// Allocate a GPU buffer of `count` floats, fill each with `value` via a Metal
// compute kernel compiled at runtime, then verify the readback.
SmokeResult gpu_smoke_fill(std::uint32_t count, float value);

// --- Outbound-string accessors ----------------------------------------------
// std::string <-> Swift.String bridging is unavailable on the Command-Line-
// Tools toolchain, so std::string is never exposed across the interop boundary.
// Instead, callers pass a buffer and we copy a NUL-terminated C string into it.
// Returns the full length of the source string (excluding NUL), which may exceed
// `cap - 1` if truncated. Pass cap == 0 to query the required length.
std::size_t smoke_device_name(const SmokeResult& r, char* out, std::size_t cap);
std::size_t smoke_error(const SmokeResult& r, char* out, std::size_t cap);

// --- M1: Perlin fBm generation ----------------------------------------------

// Swift-safe parameters for a Perlin fBm heightfield.
struct PerlinParams {
    std::uint32_t width = 1024;
    std::uint32_t height = 1024;
    std::uint32_t seed = 1337;
    std::uint32_t octaves = 6;
    float frequency = 4.0f;     // base cells across the unit domain
    float lacunarity = 2.0f;    // frequency multiplier per octave
    float gain = 0.5f;          // amplitude multiplier per octave (persistence)
};

struct GenerateResult {
    bool ok = false;
    std::string error;          // populated when ok == false (read via accessor)
    std::uint32_t width = 0;
    std::uint32_t height = 0;
    float minHeight = 0.0f;
    float maxHeight = 0.0f;
    double mean = 0.0;          // for verification
    double variance = 0.0;      // for verification (must be > 0 for real terrain)
};

// Generate an fBm Perlin heightfield on the GPU and write it to disk.
// pngPath (8-bit grayscale preview) and pfmPath (32-bit float, lossless) are
// each optional — pass nullptr to skip. Stats are always computed.
GenerateResult generate_perlin(const PerlinParams& p,
                               const char* pngPath, const char* pfmPath);

std::size_t generate_error(const GenerateResult& r, char* out, std::size_t cap);

} // namespace theia
