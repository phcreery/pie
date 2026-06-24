# color module notes

This module currently owns the editor-facing `wb_temp` and `wb_tint` math and applies it post-demosaic in `color.wgsl`.

## Temp / tint model used here

The current implementation is **Adobe-style in spirit**, but simplified:

1. Convert correlated color temperature (CCT) to a white-point chromaticity in CIE 1931 `xy`.
2. Convert `xy` to CIE 1976 `u'v'`.
3. Move tint approximately **perpendicular to the local daylight / Planckian locus** in `u'v'`.
4. Convert back to `xy`, then to `XYZ` with `Y = 1`.
5. Convert the white point into camera-space response using `cam_from_xyz_d65 = inverse(xyz_d65_from_cam)`.
6. Convert that camera response into white-balance gains by taking the inverse response, normalized so green is 1.0.
7. Normalize those gains against the module defaults (`5500K`, `0 tint`) and apply the **relative** RGB correction to the already-demosaiced camera RGB before `srgb_from_cam` conversion.

In code this is done by `computeWhiteBalanceFromTempTint()` in both Zig and WGSL.

### Why tint is applied in `u'v'`

A naive implementation that offsets `x/y` directly tends to behave poorly because perceptual distance is very non-uniform there. Adobe's DNG SDK also works in a `uv`-style chromaticity space and expresses tint as an offset from the temperature locus, which is why this module now does the same general kind of thing.

### Why neutral settings preserve the upstream WB

The raw-domain/as-shot white balance from `i-raw` is already baked into the pixels before this module runs.

So the color shader computes:

- `neutral_wb`: the computed white balance for the module defaults (`5500K`, `0 tint`)
- `target_wb`: the computed white balance for the requested temp/tint
- `relative_wb = target_wb / neutral_wb`

Then it applies:

`rgb_cam_adjusted = rgb_cam * relative_wb`

before camera-to-sRGB conversion.

This means the editor defaults do **not** overwrite the upstream as-shot WB. Instead, temp/tint acts as a relative post-demosaic adjustment around the defaults.

## What a DNG white-balance pipeline should look like

At a high level, a DNG-style white-balance pipeline is not just "pick a Kelvin value and scale RGB". A more complete implementation looks like this:

1. **Start from a requested white point**
   - either as an explicit `xy` white,
   - or from temp/tint converted through Adobe's `dng_temperature` logic.

2. **Convert temp/tint into a white chromaticity**
   - Adobe's SDK uses a table-based representation of the temperature locus in `uv` space,
   - converts tint into an offset from that locus,
   - and converts the adjusted `uv` coordinate back to `xy`.

3. **Choose the correct camera calibration set**
   - DNG profiles may have 1, 2, or 3 illuminants,
   - each illuminant can carry its own `ColorMatrix`, `ForwardMatrix`, `ReductionMatrix`, and `CameraCalibration`.

4. **Interpolate between illuminants in inverse-temperature space**
   - this is a key DNG detail,
   - the SDK computes interpolation weights from `1 / temperature`, not temperature directly.

5. **Build the white-specific XYZ->Camera transform**
   - this uses the selected/interpolated calibration matrices,
   - plus `AnalogBalance`, and optionally `CameraCalibration`,
   - to produce the effective transform for the requested white point.

6. **Compute the camera white / neutral**
   - conceptually: `camera_white = XYZtoCamera(white_xyz)`
   - then normalize that camera white so it can be used as the neutral reference.

7. **Use that neutral in the rendering path**
   - in a raw-first pipeline, this usually means applying the neutral before or during demosaic,
   - then applying the proper camera-to-PCS / camera-to-output conversion using the matched DNG matrices.

8. **Use `ForwardMatrix` / PCS mapping when available**
   - DNG rendering is not only about white-balance gains,
   - it also defines how to get from camera space to PCS / XYZ D50 and then to the chosen output space.

## What this module is currently missing

Compared to a fuller DNG implementation, this module currently does **not** have:

- multiple illuminants / dual-illuminant interpolation
- explicit `ColorMatrix1/2(/3)` and `ForwardMatrix1/2(/3)` handling
- `CameraCalibration` support
- `AnalogBalance` support
- `ReductionMatrix` support
- Adobe's exact table-based `dng_temperature` conversion
- a true raw-domain neutral application tied to the final selected white point
- a full PCS / D50 rendering path derived from DNG profile data

Instead, this module uses:

- one internal `xyz_d65_from_cam` matrix,
- an analytic CCT->`xy` approximation,
- a local-locus-normal tint approximation in `u'v'`,
- and a **post-demosaic relative correction** before `srgb_from_cam`.

That makes it a useful and stable editor control, but it is still an approximation of DNG behavior, not a complete DNG white-balance/rendering pipeline.

## Important caveat

This is still not full Adobe / DNG behavior.

The current approach is a stable approximation suitable for editor controls, but not yet a faithful implementation of the DNG model described in Chapter 6 of the spec and in the DNG SDK.

## References / sources

### Adobe / DNG

- Adobe DNG Specification, Chapter 6: _Mapping Camera Color Space to CIE XYZ Space_
  - https://helpx.adobe.com/camera-raw/digital-negative.html
  - mirror PDF used during development: https://paulbourke.net/dataformats/dng/dng_spec_1_6_0_0.pdf
  - https://helpx.adobe.com/content/dam/help/en/camera-raw/digital-negative/jcr_content/root/content/flex/items/position/position-par/download_section_733958301/download-1/DNG_Spec_1_7_1_0.pdf
- Adobe DNG SDK `dng_temperature.cpp`
  - https://android.googlesource.com/platform/external/dng_sdk/+/de700ad461e35af50b28b861943a0b0753b10929/source/dng_temperature.cpp
  - notable details:
    - tint is represented as an offset from the temperature locus in `uv`
    - `kTintScale = -3000.0`
    - conversion back to `xy` is done from the adjusted `uv` coordinate
- Adobe DNG SDK `dng_color_spec.cpp`
  - https://android.googlesource.com/platform/external/dng_sdk/+/de700ad461e35af50b28b861943a0b0753b10929/source/dng_color_spec.cpp
  - see `FindXYZtoCamera_*`, white-point interpolation, and `fCameraWhite = colorMatrix * XYtoXYZ(fWhiteXY)`
- Adobe DNG SDK `dng_xy_coord.cpp`
  - https://android.googlesource.com/platform/external/dng_sdk/+/de700ad461e35af50b28b861943a0b0753b10929/source/dng_xy_coord.cpp

### Background color science

- `u'v'` / temperature / tint discussion with DNG references
  - https://photo.stackexchange.com/questions/122251/how-do-color-values-change-mathematically-as-you-change-temperature-and-tint
  - https://github.com/colour-science/colour-hdri/blob/develop/colour_hdri/models/dng.py

## Current implementation status

Implemented in `module.zig` and `color.wgsl`:

- fixed `u'v' -> xy` inverse
- stable chromaticity sanitization
- tint offset along the local locus normal
- WB gains from inverse camera response
- relative normalization around default temp/tint
- post-demosaic relative RGB correction before `srgb_from_cam`

## Future implementation plan

A reasonable path from the current approximation toward a fuller DNG-style implementation:

- [ ] keep current post-demosaic temp/tint path as a useful preview / fallback mode
- [ ] expose a clear distinction between:
  - [ ] raw-domain white-balance neutral selection
  - [ ] post-demosaic color-temperature adjustment
- [ ] ingest richer camera/profile metadata if available:
  - [ ] `ColorMatrix1/2(/3)`
  - [ ] `ForwardMatrix1/2(/3)`
  - [ ] `CameraCalibration1/2(/3)`
  - [ ] `AnalogBalance`
  - [ ] illuminant temperatures / white points
- [ ] add Adobe/DNG-style temp/tint conversion using the SDK's table-driven `uv` model
- [ ] support 1-, 2-, and 3-illuminant profiles
- [ ] interpolate calibrations in inverse-temperature space
- [ ] compute the selected camera neutral from the interpolated XYZ->Camera transform
- [ ] apply the selected neutral in the raw-domain path before or during demosaic
- [ ] use the matched forward / PCS transform for camera->XYZ(D50)->output conversion
- [ ] validate against DNG SDK / ACR behavior on a few known test images
- [ ] tune UI scaling so temp/tint slider feel is close to Lightroom / ACR
- [ ] optionally cache both `xyz_d65_from_cam` and `cam_from_xyz_d65` if repeated inversion becomes annoying or expensive
