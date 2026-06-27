# Theia

A node-based procedural terrain generator for macOS, built on Metal compute —
a Mac-native take on tools like GAEA and World Machine (which are Windows-only).

Terrain is built as a graph of operations on a heightfield: generate base noise,
carve it with hydraulic and thermal erosion, then shape it with filters. All the
heavy work runs as Metal compute kernels on the GPU.

> **Status:** headless core engine + CLI. No GUI / node editor yet.

## Requirements

- macOS on Apple Silicon (developed on M4, Metal 4)
- Swift 6 toolchain — **Command Line Tools is enough, full Xcode not required**

No external package dependencies to fetch: Metal access (metal-cpp), JSON
(nlohmann/json) and PNG (stb_image_write) are vendored under
`Sources/TheiaCore/third_party/`.

## Build & run

```sh
swift build

# Sanity-check the GPU compute path
swift run theia-cli smoke

# Generate fBm Perlin noise
swift run theia-cli demo --size 1024 --out terrain.png

# Evaluate a node graph (writes a 16-bit PNG + a 32-bit float PFM)
swift run theia-cli run examples/showcase.json --size 1024 --out terrain.png

# List node types
swift run theia-cli nodes

# Run the test suite
swift run theia-tests
```

Each run writes a 16-bit grayscale PNG (preview) and a `.pfm` (lossless float
heightmap) next to it.

## Node types

| type        | inputs | description                                              |
|-------------|:------:|----------------------------------------------------------|
| `perlin`    |   0    | fBm Perlin noise (seed, octaves, frequency, lacunarity, gain) |
| `hydraulic` |   1    | hydraulic erosion, Mei et al. 2007 virtual-pipes model   |
| `thermal`   |   1    | thermal erosion (talus-angle relaxation)                 |
| `terrace`   |   1    | quantize heights into stratified terraces                |
| `normalize` |   1    | stretch the actual range to [0,1]                        |
| `slopemask` |   1    | [0,1] mask from terrain steepness                        |
| `scalebias` |   1    | affine remap `clamp(in*scale + bias)`                    |
| `combine`   |   2    | linear blend of two inputs                               |

See `examples/` for graph files.

## Architecture

- **`TheiaCore`** — portable C++ engine. All Metal usage (via metal-cpp) is kept
  behind private headers; the public API in `include/Theia/Theia.hpp` stays
  Swift-safe so it bridges cleanly over Swift/C++ interop.
- **`theia-cli`** — thin Swift shell over the core.
- **Graph evaluation** is demand-driven from a sink with content-hash
  memoization: a node recomputes only when its own parameters or some upstream
  output actually change.
- **Shaders** are compiled from MSL source at runtime (the offline `metal`
  compiler isn't available with Command Line Tools alone).

## Roadmap

The core is in place (noise, erosion, filters, graph engine, JSON I/O). Next:
richer/more realistic erosion, more nodes, a 3D viewport, and a node-editor GUI.
