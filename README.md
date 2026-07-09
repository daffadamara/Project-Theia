# Theia

**Current version:** `0.9.0-alpha.1`

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

# Print version/API details and check local capabilities
swift run theia-cli version
swift run theia-cli doctor

# Generate fBm Perlin noise
swift run theia-cli demo --size 1024 --out terrain.png

# Evaluate a node graph (writes a 16-bit PNG + a 32-bit float PFM)
swift run theia-cli run examples/showcase.json --size 1024 --out terrain.png

# List node types, optionally as parseable JSON
swift run theia-cli nodes
swift run theia-cli nodes --json

# Diagnose graph authoring health
swift run theia-cli diagnose examples/foundation.json
swift run theia-cli diagnose examples/foundation.json --json

# Export engine-ready assets
swift run theia-cli export examples/foundation.json \
  --size 256 \
  --out-dir /private/tmp/theia-export \
  --basename foundation \
  --heightmap png16 \
  --mesh obj

# Run the test suite
swift run theia-tests
```

The `demo` and `run` commands write a 16-bit grayscale PNG preview and a `.pfm`
lossless float heightmap next to it.

CLI global flags are available on every command: `--help`, `--version`,
`--json`, `--quiet`, `--no-color`, and `--verbose`. Unknown options return exit
code `2` instead of being ignored. Runtime/load/evaluation/export failures
return exit code `1`.

Export supports the main engine-facing formats:

```sh
# Heightmap formats: png16, r16, pfm32, none
# Mesh formats: obj, none
swift run theia-cli export examples/foundation.json \
  --heightmap r16 --mesh obj --out-dir /private/tmp/theia-export
```

The legacy Phase 6 `--maps height,pfm,normal,slope,mask` flag remains accepted
as a compatibility alias, but new scripts should prefer `--heightmap` and
`--mesh`.

The viewer can display the active node as shaded terrain, height, mask, slope,
normal, or material preview. In `auto` mode, mask-style nodes such as
`slopemask` and `river` are shown as overlays on their upstream terrain instead
of being treated as displaced terrain geometry.
When a mask preview is active, the viewport exposes an erase brush for hiding
unwanted mask strokes; those edits are saved as optional `ui` metadata and are
ignored by the headless core loader.

Viewport navigation follows common 3D editor conventions: left-drag orbits,
Shift-left-drag / middle-drag / right-drag pans, wheel or pinch zooms,
Option-right-drag dollies, and focused viewport keys `F` and `7`
reset the camera or snap to top view. Keys `O`, `H`, and `Z` select orbit, pan, and
zoom left-drag tools; `G`, `A`, and `W` toggle grid, axes, and wireframe. The
viewport has a Godot-style top toolbar with icon-only frame/orbit/pan/zoom
controls, grid/axis/wireframe toggles, compact projection/display/material
menus, and a camera-aware axis gizmo for snapping to X/Y/Z views.

## Node types

| type        | inputs | description                                              |
|-------------|:------:|----------------------------------------------------------|
| `perlin`    |   0    | fBm Perlin noise (seed, octaves, frequency, lacunarity, gain) |
| `ridged`    |   0    | ridged multifractal-style fBm generator                       |
| `hydraulic` |   1    | hydraulic erosion, Mei et al. 2007 virtual-pipes model   |
| `dropleterosion` | 1 | deterministic particle hydrology with discharge/momentum feedback |
| `river` | 1 | terrain-traced river mask with seed, headwaters, water, and width controls |
| `rivercarve` | 2 | carves terrain from an explicit river mask with depth/downcutting controls |
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
- **Headless API** — `include/Theia/Theia.hpp` exposes version/capabilities,
  diagnostics, node/default-param enumeration, graph evaluation, and structured
  export through Swift-safe C++ entry points. This API is stable for SwiftPM
  callers in this repo, but is not yet promised as a cross-language C ABI.
- **Graph evaluation** is demand-driven from a sink with content-hash
  memoization: a node recomputes only when its own parameters or some upstream
  output actually change.
- **Shaders** are compiled from MSL source at runtime (the offline `metal`
  compiler isn't available with Command Line Tools alone).

## Roadmap

The core is in place (noise, erosion, hydrology, filters, graph engine, JSON I/O)
and the viewer now supports graph authoring plus analysis/material preview.
Next: richer material workflows, more export targets, and broader natural-process
nodes.

## Versioning

Theia uses Semantic Versioning:

- `0.x` tracks active pre-1.0 development.
- Minor versions map to larger project phases or milestone groups.
- Patch versions are for fixes and focused UI/core polish.
- Pre-release suffixes such as `-alpha.1` indicate builds that are useful for
  testing but not yet a stable public release.

## License

Theia is licensed under the MIT License. See `LICENSE`.

Third-party libraries vendored under `Sources/TheiaCore/third_party/` keep
their own license files and notices.
