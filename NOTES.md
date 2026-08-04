## Color

- https://yuhaozhu.com/blog/cmf.html
- https://medium.com/hipster-color-science/a-beginners-guide-to-colorimetry-401f1830b65a

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
```
The facts:
- libwebgpu_dawn.a prebuilt was compiled with GCC → needs libstdc++ (__cxx11) symbols.
- Zig can only link its bundled libc++ (clang ABI) — linkSystemLibrary("stdc++") is intercepted and redirected there (with std.zig.target.isLibCxxLibName()).
- These two runtimes are ABI-incompatible. There is no clean build-API way to bridge them.

Why upstream zgpu doesn't have this problem: Google's/Chromium's Dawn builds — which zgpu's prebuilts derive from — are compiled with clang against libc++, matching Zig's bundled
runtime. That's why the commit you linked can just call linkLibCpp() and be done. Your zdawn prebuilts being GCC-built is the actual root cause.

So the non-hacky options are:

1. Rebuild/replace your Dawn prebuilts with clang + libc++ ones (e.g. build Dawn with -DCMAKE_CXX_FLAGS="-stdlib=libc++" or use Google's official builds / WebGPU-distribution
  binaries). Then plain link_libcpp = true works — exactly like upstream zgpu, no special casing anywhere. This is the correct long-term fix and belongs in the zdawn repo's
  prebuilt pipeline.

2. Accept one small escape hatch (the only way to keep GCC-built Dawn): a single cc -print-file-name=libstdc++.so + addObjectFile in zdawn's build.zig, so it's centralized in the
  dependency rather than every consumer. It's not a probing hack — just one compiler query — but it is inherently outside Zig's supported API.
```

```
Verdict: Yes — sokol-zig will work with wgpu-zig (wgpu-native v29.0.1.1), with exactly one Dawn-only symbol to patch out.

 I checked all three layers — headers, exported symbols, and API semantics:

 ### Symbol/header compatibility

 - Extracted all 182 distinct wgpu*/WGPU* symbols used by sokol_gfx.h + sokol_app.h and checked them against the exact webgpu-headers@673658bc that wgpu-zig vendors:
     - 179/182 present. The misses are:
         - WGPUExtent — false positive (my regex truncated WGPUExtent3D, which exists)
         - WGPUEmscriptenSurfaceSourceCanvasHTMLSelector — Emscripten-only, correctly guarded by #if defined(__EMSCRIPTEN__) in sokol
         - wgpuDeviceSetLoggingCallback / WGPULoggingCallbackInfo / WGPULoggingType — genuinely Dawn-only
 
 ### Implementation compatibility

 - Downloaded the actual wgpu-linux-x86_64-release.zip for v29.0.1.1 and ran nm -D on libwgpu_native.so: every function sokol calls is exported — including the new-style API
   sokol_app relies on: wgpuInstanceWaitAny, wgpuInstanceProcessEvents, wgpuDeviceGetLimits (new WGPULimits* style), wgpuSurfaceGetCurrentTexture (status-enum style),
   WGPUStringView-based callbacks. wgpu-native v25+ fully adopted the modern "future/callback-info" webgpu.h, so sokol's recent rewrite matches.
 - Semantics line up too: sokol uses WGPUCallbackMode_WaitAnyOnly/AllowProcessEvents + WGPUInstanceFeatureName_TimedWaitAny, all of which wgpu-native supports natively (it has a
   real event loop, unlike emdawnwebgpu where sokol needs fallbacks).

 ### The one required patch

 sokol_app.h:4149-4196 — on native builds (#if !defined(_SAPP_EMSCRIPTEN)), sokol unconditionally registers a Dawn-only logging callback:

 ```c
   wgpuDeviceSetLoggingCallback(_sapp.wgpu.device, cb_info);  // Dawn-only!
 ```

 You'll need to guard this out for wgpu-native (e.g. a SOKOL_WGPU_NATIVE define) — or map it to wgpu-native's extras equivalent wgpuSetLogCallback/wgpuSetLogLevel (confirmed
 exported). This is a small upstreamable patch to sokol, not a blocker.

 ### Wiring notes for pie

 - Both sides must compile against the same webgpu.h — inject wgpu-zig's vendored webgpu-headers include path into sokol_clib (same pattern you used with zdawn's dawn_headers).
 - Your wgpu_dawn module import points get replaced by wgpu-zig's idiomatic Zig bindings (Instance.init, requestAdapterSync, etc.), and you pass the resulting
   instance/adapter/device into sokol via sg_environment / sapp wgpu hooks — type-compatible since both follow the same 2025 webgpu.h lineage.
 - Bonus: no more libstdc++/libc++ ABI fight — libwgpu_native is Rust, C ABI only.
```


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
