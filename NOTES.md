## Color Notes

- https://yuhaozhu.com/blog/cmf.html
- https://medium.com/hipster-color-science/a-beginners-guide-to-colorimetry-401f1830b65a

## Raw Processing Notes:

- https://rcsumner.net/raw_guide/RAWguide.pdf
- https://www.odelama.com/photo/Developing-a-RAW-Photo-by-hand/
- https://www.odelama.com/photo/Developing-a-RAW-Photo-by-hand/Developing-a-RAW-Photo-by-hand_Part-2/
- https://www.strollswithmydog.com/raw-data-physical-units/
- https://www.strollswithmydog.com/linear-color-transforms/

- https://www.dxomark.com/Cameras/Nikon/D7100---Measurements



## Zig notes

- gpu
  - https://codeberg.org/Games-by-Mason/mr_gpu

- UI

  - https://codeberg.org/shahwali/knots
  - https://codeberg.org/Games-by-Mason/dear_imgui_zig

- Image Loaders

  - LibRaw [used by darktable]
  - rawspeed [used by darktable]
  - rawloader [used by vkdt]

- wgpu Zig bindings

  - https://git.bouvais.lu/adrien/zig-wgpu
  - https://codeberg.org/Silverclaw/zig-wgpu-native
  - https://github.com/bronter/wgpu_native_zig
    - https://github.com/carrot-sticks/wgpu_native_zig
  - https://github.com/zig-gamedev/zgpu

- Shader stuff

  - https://codeberg.org/Games-by-Mason/mr_glsl
  - https://codeberg.org/Mr_Nobody/HowToVulkan_zig
  - https://codeberg.org/andrewkraevskii/howtovulkan-zig

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
  - Interfaces in zig
    - ["raw doggin' interfaces"](https://www.youtube.com/watch?v=ZOllg8C3ows): https://www.openmymind.net/Zig-Interfaces/
    - https://github.com/permutationlock/ztrait
    - https://github.com/permutationlock/zimpl
    - https://github.com/nilslice/zig-interface
    - https://github.com/yglcode/zig_interfaces
    - https://williamw520.github.io/2025/07/13/zig-interface-revisited.html
  - https://ziggit.dev/t/convention-for-init-deinit/4865/2
  - [Zig cheatsheet](https://gist.github.com/jdmichaud/b75ee234bfa87283a6337e06a3b70767)
