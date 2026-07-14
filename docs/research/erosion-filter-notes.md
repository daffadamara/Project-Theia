# Erosion Filter Reference Gate

Audit status: **approved for Phase 8 implementation**
Audit date: 2026-07-10

## Primary sources and license

- Rune Skovbo Johansen, [Fast and Gorgeous Erosion Filter](https://blog.runevision.com/2026/03/fast-and-gorgeous-erosion-filter.html).
- Rune Skovbo Johansen, [Advanced Terrain Erosion Filter](https://www.shadertoy.com/view/wXcfWn), the published reference shader.
- Rune Skovbo Johansen, [Clean Terrain Erosion Filter](https://www.shadertoy.com/view/33cXW8), the earlier frequency-based version used to check height-path lineage.

The reference shader is MPL-2.0. The Metal port is therefore explicitly
MPL-2.0, carries source links in its header, and is listed in
`THIRD-PARTY-NOTICES.md`. Secondary ports were consulted only to verify the
source transcription when Shadertoy did not expose its text to automated
readers; they are not the algorithm authority.

## Classification

This is a point-local procedural appearance filter, not a hydraulic or sediment
simulation. Every texel is evaluated independently from the input height,
finite-difference slope, and deterministic cell noise. It does not claim
conservation of water, sediment, mass, or energy.

## Quantities, units, and normalization

- Input height `h` is a dimensionless scalar in `[0,1]`.
- Domain coordinates `u,v` are normalized to `[0,1]²`.
- Central differences estimate derivatives per normalized-domain unit:

  `dh/du ≈ (h(x+1,y) - h(x-1,y)) * (width-1)/2`

  `dh/dv ≈ (h(x,y+1) - h(x,y-1)) * (height-1)/2`

- `fadeTarget` is signed analysis data in `[-1,1]`, derived from height by
  `(h - fadeCenter) / fadeRange` and clamped.
- The public ridge field is stored in `[0,1]` using
  `ridge01 = clamp(0.5 * ridgeSigned + 0.5)`. Thus crease is `0`, neutral is
  `0.5`, and ridge is `1`.
- Scale, strength, masks, rounding, and noise phase are dimensionless artistic
  controls. They are not meters, seconds, or material coefficients.

## Boundary condition

Height sampling clamps coordinates to the closest edge texel. At the boundary,
the duplicated endpoint makes the outward finite difference zero on the missing
side. This is a clamped/zero-flux-style numerical boundary, chosen for stable
finite tiles; it is not periodic and does not guarantee seamless wrapping.

## Height equations

For each octave `i`, Phacelle noise returns cosine height `gᵢ.x` and a sine-based
derivative. With `Mᵢ` the accumulated combi-mask and `fᵢ` the fade target:

`fadedᵢ = mix([fᵢ, 0, 0], gᵢ * gullyWeight, Mᵢ)`

`heightAndSlopeᵢ₊₁ = heightAndSlopeᵢ + strengthᵢ * fadedᵢ`

`fᵢ₊₁ = fadedᵢ.x`

`Mᵢ₊₁ = powInv(Mᵢ, detail) * newMaskᵢ`

where `powInv(t,p) = 1 - (1-clamp(t,0,1))^p`. Strength is multiplied by
`gain` and frequency by `lacunarity` after every octave. The existing Phase 7
height path is unchanged in Phase 8; only parallel ridge bookkeeping and a
second output buffer were added.

## Ridge equations

The advanced method tracks an unrounded, unweighted copy of fade state so
ridge analysis is not degraded by height styling controls:

`R_f,0 = fadeTarget`

`R_M,0 = easeOut(|∇h| * ridgeTerrainOnset)`

For each octave:

`R_f,i+1 = mix(R_f,i, gᵢ.x, R_M,i)`

`R_M,i+1 = R_M,i * easeOut(|sinPhaseᵢ| * ridgeGullyOnset)`

The last octave is faded toward neutral because it has not yet passed through a
following mask:

`ridgeSigned = R_f,n * (1 - R_M,n)`

Theia currently fixes `ridgeTerrainOnset = 2.8` and
`ridgeGullyOnset = 1.5`, matching the reference shader defaults. The ridge
result is produced in the same Metal dispatch as height.

## Parameter mapping

| Theia parameter | Reference role | Accepted range |
|---|---|---:|
| `seed` | deterministic cell offsets | uint32 |
| `scale` | base gully scale and strength scale | `[0.005,1]` |
| `strength` | height contribution | `[0,1]` |
| `octaves` | repeated gully layers | `[0,8]` |
| `lacunarity` | frequency multiplier | `[1,4]` |
| `gain` | strength multiplier | `[0,1]` |
| `gullyWeight` | raw-gully contribution | `[0,1]` |
| `detail` | inverse-power combi-mask shaping | `[0.05,6]` |
| `ridgeRounding`, `creaseRounding` | height-path edge rounding | `[0,1]` |
| `onset` | height-path slope mask onset | `[0.05,8]` |
| `assumedSlope`, `slopeMix` | straight-gully direction control | `[0,8]`, `[0,1]` |
| `cellScale`, `normalization` | Phacelle cell/phase normalization | `[0.1,4]`, `[0,1]` |
| `heightOffset` | accumulated height bias | `[-1,1]` |
| `fadeCenter`, `fadeRange` | height-to-fade-target mapping | `[0,1]`, `[0.01,1]` |

## Required invariants

- `height` remains finite and clamped to `[0,1]`.
- `ridge` remains finite and clamped to `[0,1]`.
- Identical input and parameters produce bitwise deterministic outputs on the
  same supported Metal device/toolchain.
- Requesting `height` and then `ridge` cannot dispatch the node twice while the
  atomic cache entry remains valid.
- Changing any upstream content invalidates both outputs together.
- `strength = 0` preserves every height sample; ridge is neutral `0.5`.
- The output buffers have the same dimensions as the input scalar grid.

## Limitations

- Ridge is analysis/material data, not a river network. Lines can end on a
  slope and have no connectivity, downstream-flow, or conservation guarantee.
- Numerical derivatives at tile edges use clamped sampling and can differ from
  adjacent independently generated tiles unless their border samples agree.
- Partial normalization deliberately tolerates some second-order derivative
  discontinuity; the reference author reports it as visually negligible with
  multiple octaves.
- The filter works best over smooth broad landforms. Feeding detail-heavy fBm
  stacks unrelated high-frequency structures and can look noisy.
- RGB/RGBA material layers and physically based erosion outputs are outside
  Phase 8.
