# PIE

Peyton's Image Editor

heavily inspired by [vkdt](https://github.com/hanatos/vkdt)

> NOTE: this is under heavy development and experimentation. It is mostly a personal project to learn about zig, webgpu, and image processing. The git history is inconsistent because of this as well as using it as a sync between computers.

## Status

A long way to go.

![alt text](image.png)

**Left: Output of dcraw from libraw, Right: output of pie basic pipeline. These should be a close as possible.**

## Development

```
zig build integration -fincremental --watch --error-style minimal_clear
zig build test --watch
zig build integration --watch
```

To build and run the experimental web version:

`zig build --release=small -Dtarget=wasm32-emscripten run`

This may require changing the default allocator.

## Build Requirements

zig 0.16.0

### Linux

`alsa-lib-devel libX11-devel mesa-libGL mesa-libGL-devel libXi-devel libXcursor-devel`
