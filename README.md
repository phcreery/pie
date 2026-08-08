# PIE

Peyton's Image Editor

heavily inspired by [vkdt](https://github.com/hanatos/vkdt)

> NOTE: this is under heavy development and experimentation. It is mostly a personal project to learn about zig, webgpu, and image processing. The git history is inconsistent because of this ... as well as using it as a file sync between computers.

## Status

Build a basic pipeline. The pipeline is a DAG but it makes many false assumptions.

The pipeline does basic raw -> srgb. Thats just about it.

```
▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒ NODES ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
┌──────────────────────────────────────────────────────────────────┐
│ [x] source | i-raw : source                                      │
└─▼────────────────────────────────────────────────────────────────┘
  │
  ├┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄ rggb16uint 4016x1504
  │
┌─▼────────────────────────────────────────────────────────────────┐
│ [x] compute | format : u16_to_f16                                │
└─▼────────────────────────────────────────────────────────────────┘
  │
  ├┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄ rggb16float 4016x1504
  │
┌─▼────────────────────────────────────────────────────────────────┐
│ [x] compute | denoise : interpolation                            │
└─▼────────────────────────────────────────────────────────────────┘
  │
  ├┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄ rggb16float 4016x1504
  │
┌─▼────────────────────────────────────────────────────────────────┐
│ [x] compute | demosaic : halfsize                                │
└─▼────────────────────────────────────────────────────────────────┘
  │
  ├┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄ rgba16float 2008x3008
  │
┌─▼────────────────────────────────────────────────────────────────┐
│ [x] compute | color : color                                      │
└─▼────────────────────────────────────────────────────────────────┘
  │
  ├┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄ rgba16float 2008x3008
  │
┌─▼────────────────────────────────────────────────────────────────┐
│ [x] compute | filmcurv : filmcurv                                │
└─▼────────────────────────────────────────────────────────────────┘
  │
  ├┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄ rgba16float 2008x3008
  │
┌─▼────────────────────────────────────────────────────────────────┐
│ [x] sink | o-png : sink                                          │
└──────────────────────────────────────────────────────────────────┘
```

## Development

```
zig build test --watch --error-style minimal_clear
zig build integration --watch --error-style minimal_clear -freference-trace=100
zig build app --watch --error-style minimal_clear --fork=../zgpu
```

To build and run the experimental web version:

`zig build --release=small -Dtarget=wasm32-emscripten run`

This may require changing the default allocator.

## Build Requirements

zig 0.17.0-dev.1464+6aff551f1

To use 0.16.0 zls on master, `ln ~/.local/share/zvm/0.16.0/zls ~/.local/share/zvm/bin/zls` or `ln ~/.zvm/0.16.0/zls ~/.zvm/bin/zls`

### Linux

`alsa-lib-devel libX11-devel mesa-libGL mesa-libGL-devel libXi-devel libXcursor-devel`
`libX11-devel libXi-devel libXcursor-devel libXrandr-devel mesa-libGL-devel`
