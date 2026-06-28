# Theia

A node-based procedural terrain generator for macOS, built on Metal compute —
a Mac-native take on tools like GAEA and World Machine (which are Windows-only).

Terrain is built as a graph of operations on a heightfield: generate base noise,
carve it with hydraulic and thermal erosion, then shape it with filters. All the
heavy work runs as Metal compute kernels on the GPU.

> **Status:** headless core engine + CLI + macOS 3D viewer/node editor with
> mask/material preview modes.

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

The viewer can display the active node as shaded terrain, height, mask, slope,
normal, or material preview. In `auto` mode, mask-style nodes such as
`slopemask` are shown as an overlay on their upstream terrain instead of being
treated as displaced terrain geometry.

## Node types

| type        | inputs | description                                              |
|-------------|:------:|----------------------------------------------------------|
| `perlin`    |   0    | fBm Perlin noise (seed, octaves, frequency, lacunarity, gain) |
| `ridged`    |   0    | ridged multifractal-style fBm generator                       |
| `hydraulic` |   1    | hydraulic erosion, Mei et al. 2007 virtual-pipes model   |
| `thermal`   |   1    | thermal erosion (talus-angle relaxation)                 |
| `terrace`   |   1    | quantize heights into stratified terraces                |
| `normalize` |   1    | stretch the actual range to [0,1]                        |
| `slopemask` |   1    | [0,1] mask from terrain slope angle                      |
| `scalebias` |   1    | affine remap `clamp(in*scale + bias)`                    |
| `combine`   |   2    | linear blend of two inputs                               |
| `invert`    |   1    | crossfade between heightfield and inverse                 |
| `clamp`     |   1    | clamp heights to a min/max band                           |
| `remap`     |   1    | remap an input interval with gamma shaping                |
| `blur`      |   1    | deterministic clamped-edge box blur                       |
| `warp`      |   1    | domain-warp source sampling with procedural displacement  |
| `blend`     |   2    | blend two inputs with mix/add/multiply/max/min/screen     |

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

The core is in place (noise, erosion, filters, graph engine, JSON I/O) and the
viewer now supports graph authoring plus analysis/material preview. Next:
export pipeline, richer material workflows, and more natural-process nodes.
