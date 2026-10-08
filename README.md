# PIE

Peyton's Image Editor

heavily inspired by [vkdt](https://github.com/hanatos/vkdt)

> NOTE: this is under heavy development and experimentation. It is mostly a personal project to learn about zig, webgpu, and image processing. The git history is inconsistent because of this ... as well as using it as a file sync between computers.

## Status

Build a basic pipeline. The pipeline is a DAG but it makes many false assumptions.

The pipeline does basic raw -> srgb. Thats just about it.

```
▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒ NODES ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
┌───────────────────────────────────────────────────────┐
│ [x] i-raw : source                                    │
└─▼─────────────────────────────────────────────────────┘
  │
  ├┄┄┄┄┄┄┄┄┄┄┄┄┄┄ camera linear any rggb16uint 4016x6016
  │
┌─▼─────────────────────────────────────────────────────┐
│ [x] format : format                                   │
└─▼─────────────────────────────────────────────────────┘
  │
  ├┄┄┄┄┄┄┄┄┄┄┄┄┄ camera linear any rggb32float 4016x6016
  │
┌─▼─────────────────────────────────────────────────────┐
│ [x] denoise : interpolation                           │
└─▼─────────────────────────────────────────────────────┘
  │
  ├┄┄┄┄┄┄┄┄┄┄┄┄┄ camera linear any rggb32float 4016x6016
  │
┌─▼─────────────────────────────────────────────────────┐
│ [x] demosaic : halfsize                               │
└─▼─────────────────────────────────────────────────────┘
  │
  ├┄┄┄┄┄┄┄┄┄┄┄┄┄ camera linear any rgba16float 2008x3008
  │
┌─▼─────────────────────────────────────────────────────┐
│ [x] crop : rotate_center                              │
└─▼─────────────────────────────────────────────────────┘
  │
  ├┄┄┄┄┄┄┄┄┄┄┄┄┄ camera linear any rgba16float 3008x2008
  │
┌─▼─────────────────────────────────────────────────────┐
│ [x] color : color                                     │
└─▼─────────────────────────────────────────────────────┘
  │
  ├┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄ srgb linear d65 rgba16float 3008x2008
  │
┌─▼─────────────────────────────────────────────────────┐
│ [x] filmcurv : filmcurv                               │
└─▼─────────────────────────────────────────────────────┘
  │
  ├┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄ srgb linear d65 rgba16float 3008x2008
  │
┌─▼─────────────────────────────────────────────────────┐
│ [x] o-display : o-display                             │
└───────────────────────────────────────────────────────┘
```

you can write compute shaders in wgsl, glsl, or zig (with the new spir-v backend)

## Development

```
zig build test --watch --error-style minimal_clear
zig build integration --watch --error-style minimal_clear -freference-trace=100
```

### App

```
zig build app --error-style minimal_clear
```

## Build Requirements

zig 0.17.0-dev.1464+6aff551f1

### Linux

`alsa-lib-devel libX11-devel mesa-libGL mesa-libGL-devel libXi-devel libXcursor-devel`
`libX11-devel libXi-devel libXcursor-devel libXrandr-devel mesa-libGL-devel libgtk-3-dev`
