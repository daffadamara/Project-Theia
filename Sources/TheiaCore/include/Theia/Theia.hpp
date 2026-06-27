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

// --- M2: Node graph engine (opaque-handle C-style API) ----------------------
//
// The graph engine is driven through an opaque handle so nothing non-Swift-safe
// (Metal types, std::string) crosses the interop boundary. Build a graph
// programmatically (add nodes, set params, connect) or load it from JSON, then
// evaluate a sink at a resolution. Bool-returning calls store a message
// retrievable via graph_last_error().
//
// Node types: "perlin" (0 inputs), "scalebias" (1 input), "combine" (2 inputs),
// "hydraulic" (1 input, pipe-model erosion), "thermal" (1 input, talus relaxation).

struct GraphHandle;  // opaque; defined in the implementation

GraphHandle* graph_create();
void graph_destroy(GraphHandle* g);

bool graph_add_node(GraphHandle* g, const char* id, const char* type);
bool graph_set_param(GraphHandle* g, const char* id, const char* key, double value);
bool graph_connect(GraphHandle* g, const char* fromId, const char* toId,
                   std::uint32_t inputIndex);

bool graph_load_json_file(GraphHandle* g, const char* path);
bool graph_save_json_file(GraphHandle* g, const char* path);

struct GraphEvalResult {
    bool ok = false;
    std::uint32_t width = 0;
    std::uint32_t height = 0;
    std::uint32_t evaluated = 0;   // nodes (re)computed this pass
    std::uint32_t reused = 0;      // nodes served from cache this pass
    float minHeight = 0.0f;
    float maxHeight = 0.0f;
    double mean = 0.0;
    double variance = 0.0;
};

// Evaluate `sinkId` at `width` x `height`. Pass sinkId == nullptr/"" to use the
// graph's default sink, and width/height == 0 to use the graph's default
// resolution (both come from loaded JSON). Optionally writes PNG/PFM (nullptr to
// skip). The graph's cache persists across calls on the same handle, so a second
// evaluate after changing one param recomputes only the affected subgraph.
GraphEvalResult graph_evaluate(GraphHandle* g, const char* sinkId,
                               std::uint32_t width, std::uint32_t height,
                               const char* pngPath, const char* pfmPath);

std::size_t graph_last_error(GraphHandle* g, char* out, std::size_t cap);

} // namespace theia
