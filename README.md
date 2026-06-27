# PIE

Peyton's Image Editor

heavily inspired by [vkdt](https://github.com/hanatos/vkdt)

> NOTE: this is under heavy development and experimentation. It is mostly a personal project to learn about zig, webgpu, and image processing. The git history is inconsistent because of this ... as well as using it as a file sync between computers.

## Status

Does basic raw -> srgb. Thats just about it.
?Build a basic pipeline. The pipeline is a DAG but it makes many false assumptions.

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ [x] (0) source: i-raw > source                                               │
└─▼────────────────────────────────────────────────────────────────────────────┘
  │                                                          
  ├┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄ (0) rggb16uint
  │                                                          
┌─▼────────────────────────────────────────────────────────────────────────────┐
│ [x] (1) compute: format > u16_to_f16                                         │
└─▼────────────────────────────────────────────────────────────────────────────┘
  │                                                          
  ├┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄ (1) rggb16float
  │                                                          
┌─▼────────────────────────────────────────────────────────────────────────────┐
│ [x] (2) compute: denoise > interpolation                                     │
└─▼────────────────────────────────────────────────────────────────────────────┘
  │                                                          
  ├┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄ (2) rggb16float
  │                                                          
┌─▼────────────────────────────────────────────────────────────────────────────┐
│ [x] (3) compute: demosaic > halfsize                                         │
└─▼────────────────────────────────────────────────────────────────────────────┘
  │                                                          
  ├┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄ (3) rgba16float
  │                                                          
┌─▼────────────────────────────────────────────────────────────────────────────┐
│ [x] (4) compute: crop > rotate_center                                        │
└─▼────────────────────────────────────────────────────────────────────────────┘
  │                                                          
  ├┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄ (4) rgba16float
  │                                                          
┌─▼────────────────────────────────────────────────────────────────────────────┐
│ [x] (5) compute: color > color                                               │
└─▼────────────────────────────────────────────────────────────────────────────┘
  │                                                          
  ├┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄ (5) rgba16float
  │                                                          
┌─▼────────────────────────────────────────────────────────────────────────────┐
│ [x] (6) compute: filmcurv > filmcurv                                         │
└─▼────────────────────────────────────────────────────────────────────────────┘
  │                                                          
  ├┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄ (6) rgba16float
  │                                                          
┌─▼────────────────────────────────────────────────────────────────────────────┐
│ [x] (7) compute: test-nop-glsl > test-nop-glsl                               │
└─▼────────────────────────────────────────────────────────────────────────────┘
  │                                                          
  ├┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄ (7) rgba16float
  │                                                          
┌─▼────────────────────────────────────────────────────────────────────────────┐
│ [x] (8) sink: o-ppm > sink                                                   │
└──────────────────────────────────────────────────────────────────────────────┘
```

## Development

```
zig build integration --watch --error-style minimal_clear
zig build test --watch --error-style minimal_clear
```

To build and run the experimental web version:

`zig build --release=small -Dtarget=wasm32-emscripten run`

This may require changing the default allocator.

## Build Requirements

zig 0.17.0-dev.978+a078d55a2

### Linux

`alsa-lib-devel libX11-devel mesa-libGL mesa-libGL-devel libXi-devel libXcursor-devel`
