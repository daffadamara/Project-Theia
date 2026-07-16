# Theia Architecture

Theia is split into a portable graph engine and two Swift front ends.

## Core

- `TheiaCore` owns graph validation, incremental content-hash caching, Metal
  compute, CPU hydrology, editor mask edits, and all export writers.
- GPU hydraulic erosion follows a documented virtual-pipe/shallow-water update
  with non-negative water, bounded wet/dry velocity and bed exchange, then an
  input-relative conservative settling pass that removes solver-created
  needles without blurring legitimate source relief.
- `include/Theia/Theia.hpp` is the only Swift-facing API. Metal and
  implementation-only C++ types stay private.
- Graph JSON reloads are transactional. Successful reloads preserve compatible
  cache entries; failed reloads preserve the previous usable graph.
- Every input and output has a stable name and `FieldKind` (`terrain`, `mask`,
  or `data`). Generic scalar transforms inherit their primary input kind;
  terrain processes and mask consumers validate compatible kinds.
- A node evaluation is atomic across all outputs. The cache stores the complete
  output set in one entry, while downstream keys are derived from the node key,
  selected output name, and resolved kind.
- Graph format v3 retains v2 connections `{from, output, to, input}` and the
  persisted result `{sink, sinkOutput}`, then adds an optional top-level
  `materialStack`. Missing v1 output fields map to default ports; v1/v2 files
  migrate without acquiring a material stack.
- A material stack is a derived document asset over scalar graph outputs, not a
  new field kind. The core evaluates one terrain reference and up to three
  deduplicated mask/data sources, normalizes four weights, caches that derived
  RGBA field by ordered source content keys, and transactionally exports linear
  RGBA8 weights plus a channel/source manifest.
- `ui.maskErases[nodeId][outputName]` is the one semantic editor field: it participates in node
  hashes and graph evaluation so preview, downstream nodes, CLI, and viewer
  export agree. It is applied only when the resolved output kind is `mask`.
  Other `ui` fields are presentation metadata.

## Viewer

- `GraphDocument` owns the serialized authoring model and compatibility
  migrations.
- `GraphDocumentHistory` owns bounded undo/redo state.
- `TerrainModel` coordinates document mutations and MainActor presentation.
- High-frequency camera revision state lives in a dedicated observable consumed
  only by the axis gizmo; orbit/pan/zoom does not invalidate `TerrainModel` or
  rebuild the material authoring panel.
- `TerrainPreviewWorker` owns a separate graph handle on a serial background
  queue. A short coalescing window removes rapid intermediate edits; new
  snapshots supersede queued work and stale completed results are discarded.
- The ephemeral `previewReference` supplies preview data, while
  `sink`/`sinkOutput` changes only through an explicit authoring action.
  Non-terrain fields reuse a
  terrain output from the same node, or the nearest upstream terrain, as mesh
  geometry. Auto mode follows the resolved field kind.
- `TerrainEngine` is retained for synchronous validation and explicit save.
- `Renderer`, `TerrainSurfacePicker`, and `TerrainShaders` own rendering and
  surface-aware viewport interaction. Material preview passes packed scalar
  weights to Metal, decodes stored sRGB colors once on the CPU, then blends,
  lights, and encodes for the non-sRGB display target.
- Export, graph output, node inspector, viewport controls, and the main content
  shell are separate SwiftUI files to keep feature boundaries reviewable.

## Verification

- `theia-tests` covers the public core/CLI contract and GPU algorithms.
- `theia-viewer --self-test` covers authoring migrations, graph mutations,
  history, persistence, mask edit round-trips, and terrain picking without
  requiring a window.
- GitHub Actions builds and tests on the native Apple Silicon `macos-26`
  runner, validates every example graph, and uploads an offscreen Metal render.
- Mathematical or physical algorithms must first pass the documented research
  gate in `docs/research/`, with invariants mapped to executable tests.
