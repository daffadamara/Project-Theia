# Changelog

## Unreleased

## 0.10.0-alpha.2

- Stabilized `erosionfilter` defaults and extreme controls, and added
  resolution-aware octave band-limiting to prevent cell distortion,
  under-sampled micro-spikes, normalization spikes, and clipped fade holes.
- `erosionfilter` now samples the input gradient at the gully-cell scale
  (coherent gullies on detail-bearing inputs) and auto-calibrates the fade
  target from the input's measured height range (`fadeAuto`, on by default),
  matching the reference's amplitude-normalized altitude fade.

## 0.10.0-alpha.1

- Added typed named graph ports with `terrain`, `mask`, and `data` field kinds.
- Added atomic multi-output evaluation and cache entries with per-output content
  keys, plus named output enumeration/evaluation/readback APIs.
- Upgraded graph persistence to format v2 with connection source ports,
  `sinkOutput`, and output-scoped mask erases; v1 files migrate automatically.
- Added `erosionfilter.height` and `erosionfilter.ridge` in one Metal dispatch.
  Ridge is normalized analysis data where crease=`0`, neutral=`0.5`, ridge=`1`.
- Added CLI `run/export --output`, typed port metadata in `nodes --json`, named
  raster export, and rejection of OBJ export for non-terrain fields.
- Added named output ports and selection in the viewer, terrain fallback geometry
  for analysis fields, data color ramp preview, and per-output mask editing.
- Added a mandatory research gate for changes involving physics or mathematics,
  including equations, units/normalization, boundaries, invariants, mapping,
  limitations, attribution, and license audit.

- Added an experimental `erosionfilter` GPU node for fast, branching
  slope-guided gullies without modifying the existing erosion simulations.
- Fixed CLI node catalog whitespace so every node reports its real inputs and
  default parameters in text and JSON output.
- Made saved mask erase strokes part of core graph evaluation and caching, so
  previews, downstream river carving, and exports use the same edited mask.
- Fixed the river-mask radial splat falloff.
- Unified legacy slope-mask migration with the core defaults.
- Moved live preview evaluation to a latest-snapshot background worker and
  added heightfield-aware mask-brush picking.
- Split large viewer responsibilities into dedicated editor, inspector, export,
  output, viewport, history, preview-worker, and picking components.
- Added headless viewer self-tests and Apple Silicon GitHub Actions CI with an
  offscreen Metal render artifact.

## 0.9.0-alpha.1

- Hardened `theia-cli` with global flags, strict unknown-option handling,
  `version`, `doctor`, structured `nodes --json`, and `diagnose --json`.
- Added version/capability APIs for SwiftPM callers.
- Added structured export API `graph_export2` with `png16`, `r16`, `pfm32`,
  and `obj` outputs.
- Kept legacy `graph_export` and CLI `--maps` export flow as compatibility
  wrappers.
- Moved RAW R16 export into `TheiaCore` so CLI and viewer share one export path.
