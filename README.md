# PIE

Peyton's Image Editor

Requires latest zig from master branch

`zig build run --watch`

`zig build test --watch`

To build and run the web version:

`zig build --release=small -Dtarget=wasm32-emscripten run`

This may require changing the default allocator.

## Build Requirements

zig 0.15.1

## Zig notes

- Examples

  - https://github.com/riverwm/river/
    - files are structs
    - one global allocator, similar to C
    - interfaces with external c dependencies
  - https://github.com/tigerbeetle/tigerbeetle/

    - style standards: https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md

      - Construct larger structs in-place by passing an out pointer during initialization.
      - https://github.com/tigerbeetle/tigerbeetle/blob/5b485508373f5eed99cb52a75ec692ec569a6990/docs/TIGER_STYLE.md#cache-invalidation

    - large build.zig

  - https://github.com/foxnne/pixi
  - https://github.com/ghostty-org/ghostty

  - ["raw doggin' interfaces"](https://www.youtube.com/watch?v=ZOllg8C3ows): https://www.openmymind.net/Zig-Interfaces/

  - https://github.com/karlseguin/zul

  - https://ziggit.dev/t/convention-for-init-deinit/4865/2

```
  // if (builtin.target.os.tag == .emscripten) {
  //     // console.log("Hello, Emscripten!");
  //     std.os.emscripten.emscripten_run_script("console.log('Hello, Emscripten!')");
  //     std.os.emscripten.
  // }
  // std.debug.print("Hello, Zig!\n", .{});
```
