# PIE

Peyton's Image Editor

## Docs

> This image editor is heavily inspired by [vkdt](https://github.com/hanatos/vkdt). It differs in many ways such as using webgpu instead of vulkan, zig instead of c, and compute shaders in zig/wgsl/glsl instead of just glsl. It is not meant to be a re-write of vkdt, instead it is mostly a personal project to learn about zig, webgpu, and image processing. I do not know whether or not these choices are objectively better, they probably are not, but they make this project more enjoyable and educational since I am having to come up with my own implementation of may components.

At the core of pie is a image processing graph called a pipeline. The pieline is a directional graph (DAG)composed of linked modules which are a high level representation of image operations. Examples of modules include loading a raw image, demosaicing, denoising, and gamut mapping. Each is responsible for chaining nodes, which, as a step down the abstraction, are a definition of a gpu compute shader operation. In summary, a pipeline is composed of many connected modules, each module is composed of many connected nodes, and the pipeline is ran by traversing all connected nodes in order as gpu operations.

The input sockets of modules/nodes can only be connected to one upstream module/node. We allocate a texture on the GPU for each input socket. Each node reads from this input socket texture and wrties to an output texture. For n nodes, there will be >n-1 textures allocated, one for each node with input socket.

The surrent status of pie allows us to build a basic pipeline. Adding an `i-*` module sets the source, the pipeline does basic raw -> srgb, then hands the last texture to an `o-*` sink module. The gui uses sokol which expects an sRGB texture to pass to the display.

```zig
const allocator = std.testing.allocator;
const io = std.testing.io;


const cp_out = console.console.UTF8ConsoleOutput.init();
defer cp_out.deinit();

var gpu_instance = try gpu.GPU.init(allocator, io);
defer gpu_instance.deinit();


const pipeline_config: pie.pipeline.PipelineConfig = .{
    .upload_buffer_size_bytes = 128 * 1024 * 1024, // 128 MB
    .download_buffer_size_bytes = 128 * 1024 * 1024, // 128 MB
};

var pipeline = Pipeline.init(allocator, std.testing.io, &gpu_instance, pipeline_config) catch unreachable;
defer pipeline.deinit();

const mod_i_raw = try pipeline.addModule("01", "i-raw");
const mod_format = try pipeline.addModule("01", "format");
const mod_denoise = try pipeline.addModule("01", "denoise");
const mod_demosaic = try pipeline.addModule("01", "demosaic");
const mod_color = try pipeline.addModule("01", "color");
const mod_filmcurv = try pipeline.addModule("01", "filmcurv");
const mod_o_png = try pipeline.addModule("01", "o-png");

try pipeline.setModuleParam(mod_i_raw, "filename", []const u8, "testing/images/DSC_6765.NEF");
try pipeline.setModuleParam(mod_i_raw, "wb_mode", i32, 1);

try pipeline.setModuleParam(mod_filmcurv, "colormode", i32, 1);
try pipeline.setModuleParam(mod_filmcurv, "brightness", f32, 2.22);
try pipeline.setModuleParam(mod_filmcurv, "contrast", f32, 1.0);
try pipeline.setModuleParam(mod_filmcurv, "bias", f32, 0.0);

try pipeline.setModuleParam(mod_o_png, "filename", []const u8, "testing/images/DSC_6765_debayered.png");

try pipeline.connectModules(mod_i_raw, "output", mod_format, "input");
try pipeline.connectModules(mod_format, "output", mod_denoise, "input");
try pipeline.connectModules(mod_denoise, "output", mod_demosaic, "input");
try pipeline.connectModules(mod_demosaic, "output", mod_color, "input");
try pipeline.connectModules(mod_color, "output", mod_filmcurv, "input");
try pipeline.connectModules(mod_filmcurv, "output", mod_o_png, "input");
try pipeline.run();
```

```
▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒ NODES ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
┌───────────────────────────────────────────────────────┐
│ [x] i-raw : source                                    │
└─▼─────────────────────────────────────────────────────┘
  │
  ├┄┄┄┄┄┄┄┄┄┄┄┄┄┄ camera linear any rggb16uint 4016x6016
  │
┌─▼─────────────────────────────────────────────────────┐
│ [x] format : format                                   │
└─▼─────────────────────────────────────────────────────┘
  │
  ├┄┄┄┄┄┄┄┄┄┄┄┄┄ camera linear any rggb32float 4016x6016
  │
┌─▼─────────────────────────────────────────────────────┐
│ [x] denoise : interpolation                           │
└─▼─────────────────────────────────────────────────────┘
  │
  ├┄┄┄┄┄┄┄┄┄┄┄┄┄ camera linear any rggb32float 4016x6016
  │
┌─▼─────────────────────────────────────────────────────┐
│ [x] demosaic : halfsize                               │
└─▼─────────────────────────────────────────────────────┘
  │
  ├┄┄┄┄┄┄┄┄┄┄┄┄┄ camera linear any rgba16float 2008x3008
  │
┌─▼─────────────────────────────────────────────────────┐
│ [x] crop : rotate_center                              │
└─▼─────────────────────────────────────────────────────┘
  │
  ├┄┄┄┄┄┄┄┄┄┄┄┄┄ camera linear any rgba16float 3008x2008
  │
┌─▼─────────────────────────────────────────────────────┐
│ [x] color : color                                     │
└─▼─────────────────────────────────────────────────────┘
  │
  ├┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄ srgb linear d65 rgba16float 3008x2008
  │
┌─▼─────────────────────────────────────────────────────┐
│ [x] filmcurv : filmcurv                               │
└─▼─────────────────────────────────────────────────────┘
  │
  ├┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄ srgb linear d65 rgba16float 3008x2008
  │
┌─▼─────────────────────────────────────────────────────┐
│ [x] o-display : o-display                             │
└───────────────────────────────────────────────────────┘
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

## Build Requirements

zig 0.17.0-dev.1464+6aff551f1

### Linux

`alsa-lib-devel libX11-devel mesa-libGL mesa-libGL-devel libXi-devel libXcursor-devel`
`libX11-devel libXi-devel libXcursor-devel libXrandr-devel mesa-libGL-devel libgtk-3-dev`
