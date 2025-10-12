# PIE

Peyton's Image Editor

Requires latest zig from master branch

```
zig build run --watch
zig build test --watch
```

To build and run the web version:

`zig build --release=small -Dtarget=wasm32-emscripten run`

This may require changing the default allocator.

## Build Requirements

zig 0.15.1

## Zig notes

- Image Loaders

  - LibRaw
  - rawloader
  - rawspeed

- Examples

  - https://github.com/riverwm/river/
    - files are structs
    - one global allocator, similar to C
    - interfaces with external c dependencies
  - https://github.com/tigerbeetle/tigerbeetle/
    - Construct larger structs in-place by passing an out pointer during initialization.
    - https://github.com/tigerbeetle/tigerbeetle/blob/5b485508373f5eed99cb52a75ec692ec569a6990/docs/TIGER_STYLE.md#cache-invalidation
    - large build.zig
  - https://github.com/foxnne/pixi
  - https://github.com/ghostty-org/ghostty
  - https://github.com/karlseguin/zul

- Documentation
  - style standards: https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md
  - ["raw doggin' interfaces"](https://www.youtube.com/watch?v=ZOllg8C3ows): https://www.openmymind.net/Zig-Interfaces/
  - https://ziggit.dev/t/convention-for-init-deinit/4865/2
  - [Zig cheatsheet](https://gist.github.com/jdmichaud/b75ee234bfa87283a6337e06a3b70767)
