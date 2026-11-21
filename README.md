# PIE

Peyton's Image Editor

## Docs

> This image editor is heavily inspired by [vkdt](https://github.com/hanatos/vkdt). It differs in many ways such as using webgpu instead of vulkan, zig instead of c, and compute shaders in zig/wgsl/glsl instead of just glsl. It is not meant to be a re-write of vkdt, instead it is mostly a personal project to learn about zig, webgpu, and image processing. I do not know whether or not these choices are objectively better, they probably are not, but they make this project more enjoyable and educational since I am having to come up with my own implementation of may components.

At the core of pie is a image processing graph called a pipeline. The pieline is a directional graph (DAG) composed of linked modules which are a high level representation of image operations. Examples of modules include loading a raw image, demosaicing, denoising, and gamut mapping. Each is responsible for chaining nodes, which, as a step down the abstraction, are a definition of a gpu compute shader operation. In summary, a pipeline is composed of many connected modules, each module is composed of many connected nodes, and the pipeline is ran by traversing all connected nodes in order as gpu operations.

The input sockets of modules/nodes can only be connected to one upstream module/node. We allocate a texture on the GPU for each input socket. Each node reads from this input socket texture and wrties to an output texture. For n nodes, there will be >n-1 textures allocated, one for each node with input socket.

The current status of pie allows us to build a basic pipeline. Adding an `i-*` module sets the source, the pipeline does basic raw -> srgb, then hands the last texture to an `o-*` sink module. The gui uses sokol which expects an sRGB texture to pass to the display.

```
▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒ NODES ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
┌───────────────────────────────────────────────────┐
│ [x] i-raw : source                                │
└─▼─────────────────────────────────────────────────┘
  │
  ├┄┄┄┄┄┄┄┄┄┄┄┄ camera linear any rggb/u16 4016x6016
  │
┌─▼─────────────────────────────────────────────────┐
│ [x] format : format                               │
└─▼─────────────────────────────────────────────────┘
  │
  ├┄┄┄┄┄┄┄┄┄┄┄┄ camera linear any rggb/f32 4016x6016
  │
┌─▼─────────────────────────────────────────────────┐
│ [x] denoise : interpolation                       │
└─▼─────────────────────────────────────────────────┘
  │
  ├┄┄┄┄┄┄┄┄┄┄┄┄ camera linear any rggb/f32 4016x6016
  │
┌─▼─────────────────────────────────────────────────┐
│ [x] demosaic : halfsize                           │
└─▼─────────────────────────────────────────────────┘
  │
  ├┄┄┄┄┄┄┄┄┄┄┄┄ camera linear any rgba/f16 2008x3008
  │
┌─▼─────────────────────────────────────────────────┐
│ [x] crop : rotate_center                          │
└─▼─────────────────────────────────────────────────┘
  │
  ├┄┄┄┄┄┄┄┄┄┄┄┄ camera linear any rgba/f16 3008x2008
  │
┌─▼─────────────────────────────────────────────────┐
│ [x] color : color                                 │
└─▼─────────────────────────────────────────────────┘
  │
  ├┄┄┄┄┄┄┄┄┄┄┄ rec2020 linear d65 rgba/f16 3008x2008
  │
┌─▼─────────────────────────────────────────────────┐
│ [x] filmcurv : filmcurv                           │
└─▼─────────────────────────────────────────────────┘
  │
  ├┄┄┄┄┄┄┄┄┄┄ srgb gamma_srgb d65 rgba/f16 3008x2008
  │
┌─▼─────────────────────────────────────────────────┐
│ [x] o-display : o-display                         │
└───────────────────────────────────────────────────┘
```

## Development

```
zig build test --watch --error-style minimal_clear
zig build integration --watch --error-style minimal_clear -freference-trace=100
```

### App

```
zig build app --error-style minimal_clear
```

### Profiling

`-Denable_ztracy` compiles in [Tracy](https://github.com/wolfpld/tracy) markers; without it the hooks compile to no-ops.

```
zig build app -Denable_ztracy=true
```

Run the Tracy profiler (0.15.x) and attach, before or after launching the app — the client only records while a profiler is connected (`TRACY_ON_DEMAND`). The trace contains:

- zones: `frame` → `session.tick`, `Pipeline.run` → `Pipeline.reroute`/`Pipeline.execute`, one zone per executed node, and the thumbnail worker thread (`catalog`)
- memory: all host allocations through `util.allocator` (`src/mem.zig`) are reported as alloc/free events, visible in the Memory view
- plots: `frame_ms` and per-run `pipeline.run_ms`, `pipeline.upload_kib`, `pipeline.download_kib`, `pipeline.nodes_ran`
- messages: app start, graph build, image open, catalog changes, pipeline failures

Every zone, message, and allocation also carries a callstack (`-Dtracy_callstack=N`, default 8, `0` disables). macOS and Windows use the client's native port; grab the matching profiler build from the Tracy releases.

### Linux

`alsa-lib-devel libX11-devel mesa-libGL mesa-libGL-devel libXi-devel libXcursor-devel`
`libX11-devel libXi-devel libXcursor-devel libXrandr-devel mesa-libGL-devel libgtk-3-dev`

### TODO

- colorbalance before demosaic and denoise but divide them back out so color owns the whitebalancing
- patch sokol:
  - support wgpu-native. see https://github.com/phcreery/sokol-zig/tree/pie-wgpu
  - For tracy gpu profiling, add the two timestamp features to requiredFeatures when wgpuAdapterHasFeature reports them (sokol_app.h:4250), and add sapp_wgpu_get_instance().
    - WGPUNativeFeature_TimestampQueryInsideEncoders
    - the WGPUInstance at context creation (it calls wgpuInstanceProcessEvents while mapping readback buffers)
