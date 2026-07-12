## Color

- https://yuhaozhu.com/blog/cmf.html
- https://medium.com/hipster-color-science/a-beginners-guide-to-colorimetry-401f1830b65a

## Raw Processing

- https://rcsumner.net/raw_guide/RAWguide.pdf
- https://www.odelama.com/photo/Developing-a-RAW-Photo-by-hand/
- https://www.odelama.com/photo/Developing-a-RAW-Photo-by-hand/Developing-a-RAW-Photo-by-hand_Part-2/
- https://www.strollswithmydog.com/raw-data-physical-units/
- https://www.strollswithmydog.com/linear-color-transforms/

- https://www.dxomark.com/Cameras/Nikon/D7100---Measurements

- WB/CCT/CAT
  - https://www.energy.gov/cmei/ssl/articles/modifications-robertson-method-calculating-correlated-color-temperature-improve
  - https://jo.dreggn.org/vkdt/src/pipe/modules/colour/readme.html
  - https://photo.stackexchange.com/questions/122251/how-do-color-values-change-mathematically-as-you-change-temperature-and-tint
  - https://colour-hdri.readthedocs.io/en/v0.1.2/colour_hdri.models.dng.html
  - https://github.com/colour-science/colour-hdri/blob/master/colour_hdri/examples/examples_adobe_dng_sdk_colour_processing.ipynb
  - https://discuss.pixls.us/t/confused-about-d50-d65-and-cct-in-white-balance-and-color-calibration-modules/37293/10
  - https://ansel.photos/en/resources/white-balances/#fnref:2
  - https://jackchou00.com/en/posts/cat16-reversibility/

## Gpu

- https://mbty.fr/blog/gpu/compute

## Zig

- gpu
  - https://codeberg.org/Games-by-Mason/mr_gpu
  - https://code.hexops.org/hexops/mach/src/branch/main/src/sysgpu/gpu_allocator.zig

- UI
  - https://codeberg.org/shahwali/knots
  - https://codeberg.org/Games-by-Mason/dear_imgui_zig
  - as of 08-Sep-2025, sokol allows for webgou on native

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
    - https://github.com/zig-gamedev/zig-gamedev/

- Shader stuff
  - https://codeberg.org/Games-by-Mason/mr_glsl
  - https://codeberg.org/Mr_Nobody/HowToVulkan_zig
  - https://codeberg.org/andrewkraevskii/howtovulkan-zig

- Zig spirv backend
  - https://alichraghi.github.io/blog/zig-gpu/
  - https://gist.github.com/alichraghi/cc4b1db0a0a556de4f85cf06f0e7a400
  - https://github.com/snektron/shallenge/
  - https://codeberg.org/shahwali/knots/src/branch/main/src/gpu/backend/vulkan/shaders
  - https://github.com/q-uint/molten-zig
  - https://codeberg.org/7Games/zig-sdl3/src/branch/master-gpu/gpu_examples/shaders/zig

  - sokol: currently there's no way to get the data back to the CPU ... but we can create and injecting the storage buffer ourself
    - https://github.com/floooh/sokol/issues/1246
    - https://github.com/floooh/sokol/pull/1326

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
