# PIE

Peyton's Image Editor

`zig build run --watch`

`zig build test --watch`

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

  - ["raw doggin' interfaces"](https://www.youtube.com/watch?v=ZOllg8C3ows): https://www.openmymind.net/Zig-Interfaces/
