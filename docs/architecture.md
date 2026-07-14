# Theia Architecture

Theia is split into a portable graph engine and two Swift front ends.

## Core

- `TheiaCore` owns graph validation, incremental content-hash caching, Metal
  compute, CPU hydrology, editor mask edits, and all export writers.
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
- Graph format v2 connections are `{from, output, to, input}` and the active
  result is `{sink, sinkOutput}`. Missing v1 output fields map to default ports.
- `ui.maskErases[nodeId][outputName]` is the one semantic editor field: it participates in node
  hashes and graph evaluation so preview, downstream nodes, CLI, and viewer
  export agree. It is applied only when the resolved output kind is `mask`.
  Other `ui` fields are presentation metadata.

## Viewer

- `GraphDocument` owns the serialized authoring model and compatibility
  migrations.
- `GraphDocumentHistory` owns bounded undo/redo state.
- `TerrainModel` coordinates document mutations and MainActor presentation.
- `TerrainPreviewWorker` owns a separate graph handle on a serial background
  queue. New snapshots supersede queued work and stale completed results are
  discarded.
- The active named output supplies preview data. Non-terrain fields reuse a
  terrain output from the same node, or the nearest upstream terrain, as mesh
  geometry. Auto mode follows the resolved field kind.
- `TerrainEngine` is retained for synchronous validation and explicit save.
- `Renderer`, `TerrainSurfacePicker`, and `TerrainShaders` own rendering and
  surface-aware viewport interaction.
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
