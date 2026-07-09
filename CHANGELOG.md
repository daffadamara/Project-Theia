# Changelog

## 0.9.0-alpha.1

- Hardened `theia-cli` with global flags, strict unknown-option handling,
  `version`, `doctor`, structured `nodes --json`, and `diagnose --json`.
- Added version/capability APIs for SwiftPM callers.
- Added structured export API `graph_export2` with `png16`, `r16`, `pfm32`,
  and `obj` outputs.
- Kept legacy `graph_export` and CLI `--maps` export flow as compatibility
  wrappers.
- Moved RAW R16 export into `TheiaCore` so CLI and viewer share one export path.

