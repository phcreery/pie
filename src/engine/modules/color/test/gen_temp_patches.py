#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "colour-science>=0.4.6",
#     "numpy",
#     "openimageio",
# ]
# ///
"""Generate a linear EXR strip of colour patches at a few colour temperatures.

Each patch uses the CIE Illuminant D locus (`CCT_to_xy_CIE_D`), converted to
Y=1 XYZ and then to linear ITU-R BT.2020, the pipeline's working space. The
EXR is float32, so the values are neither clipped nor gamma-encoded.

Each patch is a Y=1 linear Rec.2020 white of that CCT, so it can be used as a
source image for temperature/white-balance tests. Patch N spans
`[N * PATCH_W, (N + 1) * PATCH_W)`.

Run from this directory:

    uv run gen_temp_patches.py

The CCT list defaults to the daylight locus's valid range (4000-25000 K).
"""

from __future__ import annotations

import pathlib

import colour
import numpy as np

# "A couple" of daylight temperatures: warm, neutral, D65 and cool.
CCTS: tuple[float, ...] = (2000.0, 4000.0, 5000.0, 6500.0, 10000.0, 20000.0)

PATCH_W: int = 64
PATCH_H: int = 256

OUTPUT: pathlib.Path = pathlib.Path(__file__).with_name("temp_patches_rec2020.exr")


def cct_patch_rec2020(cct: float) -> tuple[np.ndarray, np.ndarray]:
    """CIE D chromaticity and Y=1 linear Rec.2020 RGB at `cct` kelvin."""
    xy = colour.temperature.CCT_to_xy_CIE_D(cct)
    XYZ = colour.xy_to_XYZ(xy)  # Y = 1
    # Same matrix as `math.matrices.rec2020_from_xyz_d65`; no chromatic
    # adaptation, so the patch keeps its chromaticity relative to D65.
    colourspace = colour.RGB_COLOURSPACES["ITU-R BT.2020"]
    rgb = np.asarray(colourspace.matrix_XYZ_to_RGB, dtype=np.float64) @ np.asarray(
        XYZ, dtype=np.float64
    )
    return np.asarray(xy, dtype=np.float64), rgb


def main() -> None:
    width = PATCH_W * len(CCTS)
    patches = np.empty((PATCH_H, width, 3), dtype=np.float32)

    for i, cct in enumerate(CCTS):
        xy, rgb64 = cct_patch_rec2020(cct)
        rgb = rgb64.astype(np.float32)
        patches[:, i * PATCH_W : (i + 1) * PATCH_W] = rgb
        print(
            f"{cct:7.0f} K  xy=({xy[0]:.5f}, {xy[1]:.5f})  "
            f"linear Rec.2020=({rgb[0]:+.5f}, {rgb[1]:+.5f}, {rgb[2]:+.5f})"
        )

    colour.write_image(patches, str(OUTPUT))
    print(f"wrote {OUTPUT.name}: {width}x{PATCH_H}, float32 linear Rec.2020")


if __name__ == "__main__":
    main()
