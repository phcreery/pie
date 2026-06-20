# PIE

Peyton's Image Editor

heavily inspired by [vkdt](https://github.com/hanatos/vkdt)

> NOTE: this is under heavy development and experimentation. It is mostly a personal project to learn about zig, webgpu, and image processing. The git history is inconsistent because of this ... as well as using it as a file sync between computers.

## Status

Does basic raw -> srgb. Thats just about it.

## Development

```
zig build integration --watch --error-style minimal_clear
zig build test --watch --error-style minimal_clear
```

To build and run the experimental web version:

`zig build --release=small -Dtarget=wasm32-emscripten run`

This may require changing the default allocator.

## Build Requirements

zig 0.16.0

### Linux

`alsa-lib-devel libX11-devel mesa-libGL mesa-libGL-devel libXi-devel libXcursor-devel`
