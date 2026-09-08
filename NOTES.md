## Color

- https://yuhaozhu.com/blog/cmf.html
- https://medium.com/hipster-color-science/a-beginners-guide-to-colorimetry-401f1830b65a
- https://ekunazanu.foo/lab/quantifying-colour/

## Raw Processing

- https://rcsumner.net/raw_guide/RAWguide.pdf
- https://www.odelama.com/photo/Developing-a-RAW-Photo-by-hand/
- https://www.odelama.com/photo/Developing-a-RAW-Photo-by-hand/Developing-a-RAW-Photo-by-hand_Part-2/
- strollswithmydog
  - https://www.strollswithmydog.com/raw-data-physical-units/
  - https://www.strollswithmydog.com/linear-color-transforms/
- https://discuss.pixls.us/t/article-color-management-in-raw-processing/11521
- https://jo.dreggn.org/2019_sigmoid.pdf

### Camera Calibration

- https://www.dxomark.com/Cameras/Nikon/D7100---Measurements
- https://torger.se/anders/dcamprof.html
  - https://torger.se/anders/photography/camera-profiling.html\
- Series by Glenn Butcher
  - https://discuss.pixls.us/t/the-quest-for-good-color-1-spectral-sensitivity-functions-ssfs-and-camera-profiles/18002/11
  - https://discuss.pixls.us/t/the-quest-for-good-color-2-spectral-profiles-on-the-cheap/18286
  - https://discuss.pixls.us/t/the-quest-for-good-color-3-how-close-can-it8-come-to-ssf/18689
- https://openaccess.thecvf.com/content_iccv_workshops_2013/W25/papers/Prasad_Quick_Approximation_of_2013_ICCV_paper.pdf
- https://color-lab-eilat.github.io/Spectral-sensitivity-estimation-web/

### WB/CCT/CAT

- https://www.energy.gov/cmei/ssl/articles/modifications-robertson-method-calculating-correlated-color-temperature-improve
- https://jo.dreggn.org/vkdt/src/pipe/modules/colour/readme.html
- https://photo.stackexchange.com/questions/122251/how-do-color-values-change-mathematically-as-you-change-temperature-and-tint
- https://colour-hdri.readthedocs.io/en/v0.1.2/colour_hdri.models.dng.html
- https://github.com/colour-science/colour-hdri/blob/master/colour_hdri/examples/examples_adobe_dng_sdk_colour_processing.ipynb
- https://discuss.pixls.us/t/confused-about-d50-d65-and-cct-in-white-balance-and-color-calibration-modules/37293/10
- https://ansel.photos/en/resources/white-balances/#fnref:2
- https://jackchou00.com/en/posts/cat16-reversibility/

### vkdt

#### order of operations

```
// Order of Operations:
// dt_graph_run_modules
// - modify_roi_out
// - modify_roi_in
// - create_nodes
//   - module.create_nodes() called here
//   - handles bypassing disabled nodes
// - init_connector_images
//   - // only allocate memory for output connectors ("write" or "source" types)
//
// dt_graph_run_nodes_allocate     (potentially free/re-allocate memory, create buffers, images, image_views, and descriptor sets)
// - 1. alloc_outputs()  allocate output buffers and create compute shaders for each node
// - 2. alloc_outputs2() bind_buffers_to_memory (vkBindImageMemory)
// - 3. alloc_outputs3() create_descriptor_sets for each node
// dt_graph_run_nodes_upload       (upload all source data to staging memory) (read_source called here)
// dt_graph_run_modules_upload_uniforms
// dt_graph_run_nodes_record_cmd
// (submit queue)
// dt_graph_run_nodes_download     (download sink data from GPU to CPU)
```

- Module
  - /// vkdt dt_module_t https://github.com/hanatos/vkdt/blob/632165bb3cf7d653fa322e3ffc023bdb023f5e87/src/pipe/module.h#L107
  - /// vkdt dt_module_so_t https://github.com/hanatos/vkdt/blob/632165bb3cf7d653fa322e3ffc023bdb023f5e87/src/pipe/global.h#L62

- Node
  - // vkdt dt_node_t https://github.com/hanatos/vkdt/blob/632165bb3cf7d653fa322e3ffc023bdb023f5e87/src/pipe/node.h#L19

### Misc

- https://www.photonstophotos.net/

## Gpu

- https://mbty.fr/blog/gpu/compute

## Zig

- UI
  - https://codeberg.org/shahwali/knots
  - https://codeberg.org/Games-by-Mason/dear_imgui_zig
  - as of 08-Sep-2025, sokol allows for webgpu on native

- Image Loaders
  - LibRaw [used by darktable]
  - rawspeed [used by darktable]
  - rawloader [used by vkdt]

- gpu
  - https://codeberg.org/Games-by-Mason/mr_gpu
  - https://code.hexops.org/hexops/mach/src/branch/main/src/sysgpu/gpu_allocator.zig

- wgpu bindings
  - https://git.bouvais.lu/adrien/zig-wgpu
  - https://codeberg.org/Silverclaw/zig-wgpu-native
  - https://github.com/bronter/wgpu_native_zig
    - https://github.com/carrot-sticks/wgpu_native_zig
  - https://codeberg.org/shahwali/wgpu-zig

- dawn bindings
  - https://github.com/zig-gamedev/zgpu
    - "error: not an ELF file while parsing libzdawn.a" https://github.com/zig-gamedev/zgpu/issues/22
    - 0.17.0 https://github.com/zig-gamedev/zgpu/pull/29
    - https://github.com/zig-gamedev/zig-gamedev/
    - https://github.com/a-day-old-bagel/zgpu
  - https://github.com/akunaakwei/zig-dawn
  - Note: dawn provides a couple pre-compiled static libs, but the linux does not work since it is compiled with gnu, and according to a llm:

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
    - see compileZigToSpirv() for
    - dynamic imports of shaders: https://codeberg.org/7Games/zig-sdl3/src/branch/master-gpu/build/shaders.zig
  - https://codeberg.org/ziglang/zig/src/branch/master/lib/std/spirv.zig
  - https://codeberg.org/ziglang/zig/src/branch/master/test/cases/callconv_spirv.zig
  - https://codeberg.org/ziglang/zig/src/branch/master/test/cases/image_sampling_spirv.zig
  - https://codeberg.org/andrewrk/daw/src/branch/main/src/shaders/ui.zig

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
