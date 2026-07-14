# Material Layer Stack Reference Audit

Status: **approved for Phase 9 implementation**
Reviewed: 2026-07-14
Scope: scalar terrain/mask/data inputs, four-channel material weights, RGBA8
packing, and solid-color viewer preview. This note does not authorize automatic
biome classification, texture synthesis, PBR, or a new physical simulation.

## Primary and official references

1. Khronos Group, *glTF 2.0 Specification*.
   <https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html>
   - Normalized unsigned-byte weights have an integer sum of 255 before
     normalization.
   - Color values encoded with the sRGB transfer function are decoded to linear
     light before computation.
   - Status: official open specification; no source code is copied.
2. Epic Games, *Landscape Materials* and *Landscape Paint Mode*.
   <https://dev.epicgames.com/documentation/en-us/unreal-engine/landscape-materials-in-unreal-engine>
   <https://dev.epicgames.com/documentation/en-us/unreal-engine/landscape-paint-mode-in-unreal-engine>
   - Weight-blended layers use values in `[0,1]`, retain a total influence of
     100%, and their 8-bit stored weights add to 255.
   - Status: official product documentation used as an interoperability
     contract; no source code is copied.
3. Apple, *MTLPixelFormat*.
   <https://developer.apple.com/documentation/metal/mtlpixelformat>
   - `Unorm` formats are normalized unsigned data. `_sRGB` formats apply the
     sRGB transfer conversion to RGB while alpha remains linear.
   - Status: official platform documentation; no source code is copied.
4. W3C, *CSS Color Module Level 4*.
   <https://www.w3.org/TR/css-color-4/>
   - Defines the sRGB-to-linear and linear-to-sRGB transfer functions used by
     the preview.
   - Status: open W3C specification with sample algorithms; equations are
     restated below, not copied as an implementation.
5. W3C, *PNG Specification, Third Edition*.
   <https://www.w3.org/TR/png-3/>
   - PNG color type 6 stores samples in RGBA order and permits 8-bit samples.
   - Status: open W3C specification; the existing vendored `stb_image_write`
     implementation remains covered by its bundled license.

The largest-remainder apportionment used below is an implementation choice that
enforces the integer-sum invariant required by the glTF and Unreal contracts.
It is not presented as a physical model.

## Quantities, domains, and interpretation

- The material stack has one required base layer and zero to three overlay
  layers. Array order maps to PNG channels `R`, `G`, `B`, `A`.
- Each overlay source is a scalar graph output resolved as `mask` or `data`.
- Source values, normalized weights, and preview color components are
  dimensionless.
- Terrain values keep the existing Theia heightfield normalization. No world
  unit or physical material property is introduced.
- Preview colors are stored as non-premultiplied sRGB triples in `[0,1]`.
- The exported weight PNG is linear `RGBA8_UNORM` data. Its channels are not
  colors and must not be sampled with an sRGB texture format.

## Weight equations

For each finite overlay sample `x_i`, with `i in {1,2,3}`:

```
m_i = clamp(x_i, 0, 1)
s   = m_1 + m_2 + m_3
```

Missing overlay channels contribute `m_i = 0`. If any connected source sample
is non-finite, evaluation fails with the layer id and texel index; it is not
silently converted to zero.

For `s <= 1`:

```
w_0 = 1 - s
w_i = m_i
```

For `s > 1`:

```
w_0 = 0
w_i = m_i / s
```

The boundary `s == 1` uses the first branch. This makes the operation
continuous at the branch and gives the base layer all residual coverage before
overlay saturation. No layer ordering or alpha-over compositing is applied.

Required invariants, allowing only floating-point rounding error:

```
isfinite(w_i)
0 <= w_i <= 1
sum(w_0 ... w_3) == 1
```

## RGBA8 quantization

For each weight:

```
u_i = 255 * w_i
q_i = floor(u_i)
r   = 255 - sum(q_i)
```

Sort channels by descending fractional remainder `u_i - floor(u_i)`, breaking
ties in channel order `R, G, B, A`. Add one to the first `r` channels. Because
four non-negative fractions each remain below one, `r` is in `[0,3]`.

Required integer invariants:

```
0 <= q_i <= 255
sum(q_0 ... q_3) == 255
```

The exported PNG uses top-row-first RGBA bytes, matching the existing Theia
raster origin. It contains no `sRGB` chunk because the samples are generic
linear weights, not display colors.

## Preview color conversion

For an sRGB component `c` in `[0,1]`, convert to linear light:

```
linear(c) = c / 12.92                              if c <= 0.04045
            ((c + 0.055) / 1.055) ^ 2.4           otherwise
```

Blend in linear light:

```
C_linear = sum(w_i * linear(C_i))
```

Convert a linear component `l` back to sRGB for the existing non-sRGB render
target:

```
srgb(l) = 12.92 * l                               if l <= 0.0031308
          1.055 * l^(1/2.4) - 0.055               otherwise
```

Clamp the final display value to `[0,1]`. Terrain lighting continues to operate
in linear light before the final transfer. The preview is illustrative and is
not exported as an albedo texture.

## Boundary conditions and failure policy

- No overlays or all-zero overlays: `(1,0,0,0)`.
- Negative values clamp to zero; values greater than one clamp to one.
- Overlay overlap above one is proportionally normalized; base becomes zero.
- Duplicate output references are legal and evaluated once, but their weights
  remain independent channels.
- Terrain reference must resolve to `terrain`; overlay references must resolve
  to `mask` or `data`.
- Structural schema errors reject graph loading. Dangling or kind-incompatible
  semantic references remain diagnosable and make material evaluation/export
  fail without preventing scalar graph repair.
- Weight generation uses the requested graph resolution. All referenced fields
  therefore share dimensions; no resampling boundary is introduced.
- Bundle export validates and computes all artifacts before publishing final
  filenames. A failure may not be reported as a partial success.

## Parameter and file mapping

- `materialStack.terrain` selects the terrain heightfield used for geometry and
  terrain artifacts.
- `materialStack.layers[0]` is the source-free base and maps to channel `R`.
- Overlay array entries map sequentially to `G`, `B`, and `A`.
- `previewColorSRGB` affects viewer presentation and manifest metadata only; it
  does not invalidate graph outputs or weight values.
- `<basename>_weights.png` is `RGBA8_UNORM` linear data.
- `<basename>_material.json` records encoding, resolution, terrain reference,
  artifact names, layer ids/names/colors, channel mapping, and source refs.

## Executable invariant mapping

| Requirement | Test obligation |
|---|---|
| Residual base | zero overlays and `s < 1` exact cases |
| Saturated overlap | `s == 1`, `s > 1`, and three full overlays |
| Domain handling | negative, above-one, and non-finite inputs |
| Floating invariants | every texel finite, bounded, sum within `1e-6` |
| Integer invariants | deterministic largest-remainder ties and byte sum 255 |
| Field compatibility | terrain source and mask/data overlay validation |
| Cache behavior | duplicate refs and repeated evaluation reuse graph cache |
| Color correctness | transfer-function breakpoints and linear blend fixture |
| Raster contract | PNG color type 6, 8-bit samples, RGBA order, top-row-first |
| Persistence | v1/v2 unchanged; v3 round-trip and stable channel ordering |
| Transactionality | failed bundle leaves no final material artifacts |

## Limitations

- Four channels represent one base and at most three overlays.
- The method does not infer biomes or validate ecological plausibility.
- A `data` source is merely clamped; authors should use existing graph remap or
  clamp nodes when a centered or unbounded analysis field needs shaping.
- No texture tiling, height blend, PBR property, mip generation, compression,
  engine-specific importer, or material graph output is defined.
- `RGBA8` has finite quantization precision. The exact-sum rule avoids coverage
  drift but does not recover information lost to 8-bit storage.

## Attribution and license decision

The implementation is an original integration of documented weight and color
contracts. No third-party shader, source code, or texture asset is imported.
Project code remains MIT. Existing vendored `stb_image_write` attribution stays
in `THIRD-PARTY-NOTICES.md`; this feature adds no new redistributable dependency.
