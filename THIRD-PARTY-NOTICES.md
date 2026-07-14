# Third-Party Notices

## Experimental erosion filter

`Sources/TheiaCore/kernels/ErosionFilter.metal.hpp` implements the procedural
gully erosion technique described and published by Rune Skovbo Johansen:

- https://blog.runevision.com/2026/03/fast-and-gorgeous-erosion-filter.html
- https://www.shadertoy.com/view/33cXW8
- https://www.shadertoy.com/view/wXcfWn

The published source is licensed under the Mozilla Public License 2.0. The
Theia Metal implementation closely follows the algorithm and is distributed
under the same license. A copy of the license is available at:

https://mozilla.org/MPL/2.0/

The technique builds on earlier work by Felix Westin (Fewes) and Clay John, as
documented by the upstream author. The rest of Theia remains under the license
declared in the repository root unless a file states otherwise.
