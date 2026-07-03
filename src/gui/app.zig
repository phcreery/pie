const ig = @import("cimgui");
const sokol = @import("sokol");
const slog = sokol.log;
const sg = sokol.gfx;
const sapp = sokol.app;
const sglue = sokol.glue;
// const simgui = sokol.imgui;
const std = @import("std");
const util = @import("../mem.zig");
const builtin = @import("builtin");

const window = @import("window.zig");
const pie = @import("pie");
const console = @import("console");
const shd = @import("texview_shader");
const wgpu = @import("wgpu_dawn");

const Image = struct {
    img: sg.Image = undefined,
    tex_view: sg.View = undefined,
    smp: sg.Sampler = undefined,
    shd: sg.Shader = undefined,
    pip: sg.Pipeline = undefined,

    width: f32 = 0.0,
    height: f32 = 0.0,
    scale: f32 = 1.0,
    offset: struct { x: f32, y: f32 } = .{ .x = 0.0, .y = 0.0 },
    color: struct { r: f32, g: f32, b: f32 } = .{ .r = 1.0, .g = 1.0, .b = 1.0 },

    fn create(self: *@This(), texture: *pie.gpu.Texture) void {
        self.width = @floatFromInt(texture.roi.w);
        self.height = @floatFromInt(texture.roi.h);
        self.scale = 1.0;
        self.offset = .{ .x = 0.0, .y = 0.0 };
        self.color = .{ .r = 1.0, .g = 1.0, .b = 1.0 };

        // Inject the existing GPU-side WebGPU texture into sokol instead of
        // trying to upload CPU pixel data. sokol will addRef() the texture and
        // create its own WGPUTextureView when we make the sg.View.
        self.img = sg.makeImage(.{
            .pixel_format = .RGBA16F,
            .width = @intCast(texture.roi.w),
            .height = @intCast(texture.roi.h),
            .wgpu_texture = @ptrCast(texture.texture),
            .label = "display-texture",
        });
        self.tex_view = sg.makeView(.{
            .texture = .{ .image = self.img },
            .label = "display-texture-view",
        });
    }
};

const AppState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    pass_action: sg.PassAction = .{},
    window: window.WindowManager,
    image: Image = undefined,

    gpu: pie.gpu.GPU = undefined,
    pipeline: pie.pipeline.Pipeline = undefined,
    modules: *pie.modules.Registry = undefined,
    arena: std.mem.Allocator = undefined,

    texture: *pie.gpu.Texture = undefined,

    const Self = @This();

    fn init(allocator: std.mem.Allocator, io: std.Io) AppState {
        const windowmgr = window.WindowManager.init(allocator);

        return .{
            .allocator = allocator,
            .io = io,
            .pass_action = .{},
            .window = windowmgr,
            .image = Image{},
        };
    }

    fn deinit(self: *Self) void {
        self.* = undefined;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        self.window.deinit(allocator);
        self.deinit();
        allocator.destroy(self);
    }
};

// export fn init() void {
export fn init_fn(ptr: ?*anyopaque) void {
    std.debug.print("init_fn called with ptr: {any}\n", .{ptr});
    const state: *AppState = @ptrCast(@alignCast(ptr));

    // initialize sokol-gfx
    sg.setup(.{
        .environment = sglue.environment(),
        .logger = .{ .func = slog.func },
    });

    // initial clear color
    state.pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{ .r = 0.05, .g = 0.5, .b = 1.0, .a = 1.0 },
    };

    // NOTE: create the fullscreen-quad pipeline lazily in frame() using the
    // actual current swapchain formats.

    state.image.smp = sg.makeSampler(.{
        .mag_filter = .NEAREST,
        .min_filter = .LINEAR,
        // .wrap_u = .CLAMP_TO_EDGE,
        // .wrap_v = .CLAMP_TO_EDGE,
    });

    std.debug.print("making pipeline...\n", .{});

    state.image.shd = sg.makeShader(shd.texviewShaderDesc(sg.queryBackend()));
    state.image.pip = sg.makePipeline(.{
        .shader = state.image.shd,
        .primitive_type = .TRIANGLE_STRIP,
        .color_count = 1,
        // .sample_count = sc.sample_count,
        // .depth = .{ .pixel_format = sc.depth_format },
        .colors = init: {
            var c: @FieldType(sg.PipelineDesc, "colors") = @splat(.{});
            c[0] = .{
                // .pixel_format = sc.color_format,
                .write_mask = .RGBA,
            };
            break :init c;
        },
    });

    const ext_device: wgpu.Device = @ptrCast(@constCast(sg.wgpuDevice().?));
    const ext_queue: wgpu.Queue = @ptrCast(@constCast(sg.wgpuQueue().?));
    state.gpu = pie.gpu.GPU.initExternal(ext_device, ext_queue) catch unreachable;

    const pipeline_config: pie.pipeline.PipelineConfig = .{
        .upload_buffer_size_bytes = 75e6,
        .download_buffer_size_bytes = 75e6,
    };
    state.pipeline = pie.Pipeline.init(state.allocator, state.io, &state.gpu, pipeline_config) catch unreachable;

    state.texture = build_image(
        state.allocator,
        state.io,
        &state.pipeline,
        state.modules,
        state.arena,
    ) catch unreachable;
    std.debug.print("texture: {any}\n", .{state.texture});
    state.image.create(state.texture);
}

export fn frame(ptr: ?*anyopaque) void {
    const state: *AppState = @ptrCast(@alignCast(ptr));

    const have_image = state.image.img.id != sg.invalid_id and state.image.tex_view.id != sg.invalid_id;

    sg.beginPass(.{ .action = state.pass_action, .swapchain = sglue.swapchain() });
    if (have_image) {
        const bindings = sg.Bindings{
            .views = init: {
                var v: [32]sg.View = @splat(.{});
                v[shd.VIEW_tex] = state.image.tex_view;
                break :init v;
            },
            .samplers = init: {
                var s: [12]sg.Sampler = @splat(.{});
                s[shd.SMP_smp] = state.image.smp;
                break :init s;
            },
        };
        const fs_params = shd.FsParams{ .mip_lod = 0.0 };
        sg.applyPipeline(state.image.pip);
        sg.applyBindings(bindings);
        sg.applyUniforms(shd.UB_fs_params, .{ .ptr = &fs_params, .size = @sizeOf(shd.FsParams) });
        sg.draw(0, 4, 1);
    }
    sg.endPass();
    sg.commit();
}

export fn cleanup(ptr: ?*anyopaque) void {
    const state: *AppState = @ptrCast(@alignCast(ptr));
    if (state.image.tex_view.id != sg.invalid_id) sg.destroyView(state.image.tex_view);
    if (state.image.img.id != sg.invalid_id) sg.destroyImage(state.image.img);
    if (state.image.smp.id != sg.invalid_id) sg.destroySampler(state.image.smp);
    if (state.image.pip.id != sg.invalid_id) sg.destroyPipeline(state.image.pip);
    if (state.image.shd.id != sg.invalid_id) sg.destroyShader(state.image.shd);
    state.pipeline.deinit();
    state.gpu.deinit();
    sg.shutdown();
}

export fn event(ev: [*c]const sapp.Event, ptr: ?*anyopaque) void {
    _ = ev;
    _ = ptr;
}

fn build_image(
    allocator: std.mem.Allocator,
    io: std.Io,
    pipeline: *pie.pipeline.Pipeline,
    modules: *pie.modules.Registry,
    arena: std.mem.Allocator,
) !*pie.gpu.Texture {
    _ = allocator;
    _ = io;

    // const config: pie.gpu.TargetConfig = @import("001_DSC_6765/target.zig").config;
    // const target_filename = "testing/integration/targets/" ++ config.name ++ "/target.ppm";
    const input_filename = "testing/images/DSC_6765.NEF";
    // const output_filename = "testing/integration/targets/" ++ config.name ++ "/output.ppm";

    const mod_i_raw = try pipeline.addModule(modules.get("i-raw").?);
    const mod_format = try pipeline.addModule(modules.get("format").?);
    const mod_denoise = try pipeline.addModule(modules.get("denoise").?);
    // const mod_whitebalance = try pipeline.addModule(modules.get("whitebalance").?);
    const mod_demosaic = try pipeline.addModule(modules.get("demosaic").?);
    const mod_crop = try pipeline.addModule(modules.get("crop").?);
    const mod_color = try pipeline.addModule(modules.get("color").?);
    const mod_filmcurv = try pipeline.addModule(modules.get("filmcurv").?);
    // const mod_test_nop_glsl = try pipeline.addModule(modules.get("test-nop-glsl").?);
    // const mod_test_nop_zig = try pipeline.addModule(modules.get("test-nop-zig").?);
    const mod_o_display = try pipeline.addModule(modules.get("o-display").?);

    try pipeline.setModuleParam(mod_i_raw, "filename", @as([]const u8, input_filename));
    try pipeline.setModuleParam(mod_i_raw, "wb_mode", @as(i32, 0));
    // try pipeline.setModuleParam(mod_color, "wb_temp", @as(f32, 6500.0));
    try pipeline.setModuleParam(mod_color, "wb_tint", @as(f32, 0.0));
    try pipeline.setModuleParam(mod_color, "wb_coeff", [3]f32{ 0.70393723, 1, 1.3611937 }); // from 1/(srgb_from_xyz*xyz_d65_from_cam*(1/wb_cam)) of DSC_6765.NEF
    try pipeline.setModuleParam(mod_filmcurv, "colormode", @as(i32, 1));
    try pipeline.setModuleParam(mod_filmcurv, "brightness", @as(f32, 3.8));
    try pipeline.setModuleParam(mod_filmcurv, "contrast", @as(f32, 1.3));
    try pipeline.setModuleParam(mod_filmcurv, "bias", @as(f32, 0.0));
    // try pipeline.setModuleParam(mod_o_display, "filename", @as([]const u8, output_filename));

    try pipeline.connectModuleSocketsByHandleName(mod_i_raw, "output", mod_format, "input");
    try pipeline.connectModuleSocketsByHandleName(mod_format, "output", mod_denoise, "input");
    // try pipeline.connectModuleSocketsByHandleName(mod_denoise, "output", mod_whitebalance, "input");
    // try pipeline.connectModuleSocketsByHandleName(mod_whitebalance, "output", mod_demosaic, "input");
    try pipeline.connectModuleSocketsByHandleName(mod_denoise, "output", mod_demosaic, "input");
    try pipeline.connectModuleSocketsByHandleName(mod_demosaic, "output", mod_crop, "input");
    try pipeline.connectModuleSocketsByHandleName(mod_crop, "output", mod_color, "input");
    try pipeline.connectModuleSocketsByHandleName(mod_color, "output", mod_filmcurv, "input");
    // try pipeline.connectModuleSocketsByHandleName(mod_filmcurv, "output", mod_test_nop_glsl, "input");
    // try pipeline.connectModuleSocketsByHandleName(mod_test_nop_glsl, "output", mod_test_nop_zig, "input");
    // try pipeline.connectModuleSocketsByHandleName(mod_test_nop_zig, "output", mod_o_ppm, "input");
    // try pipeline.connectModuleSocketsByHandleName(mod_test_nop_glsl, "output", mod_o_ppm, "input");
    try pipeline.connectModuleSocketsByHandleName(mod_filmcurv, "output", mod_o_display, "input");

    try pipeline.run(arena);

    const disp_tex = try pipeline.getDisplaySinkTexture();
    // Use the display texture for rendering
    return disp_tex;
}

pub fn run(init: std.process.Init) !void {
    // general purpose allocator for temporary heap allocations:
    // const gpa = init.gpa;
    const allocator = util.allocator;
    // default Io implementation:
    const io = init.io;
    // access to environment variables:
    // std.log.info("{d} env vars", .{init.environ_map.count()});
    // access to CLI arguments
    // const args = try init.minimal.args.toSlice(
    //     init.arena.allocator()
    // );

    // Allocate the application state on the heap to ensure it lives long enough.
    // const state = util.allocator.create(AppState) catch unreachable;
    // errdefer util.allocator.destroy(state);
    // state.* = AppState.init(util.allocator);

    // Alternatively, allocate the application state on the stack
    const state: *AppState = @constCast(&AppState.init(allocator, io));
    defer state.deinit();

    const cout = console.console.UTF8ConsoleOutput.init();
    defer cout.deinit();

    var modules = try pie.modules.Registry.init(allocator);
    defer modules.deinit();
    state.modules = &modules;

    var arena_instance = std.heap.ArenaAllocator.init(allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    state.arena = arena;

    sapp.run(.{
        .user_data = state,
        .init_userdata_cb = init_fn,
        .frame_userdata_cb = frame,
        .cleanup_userdata_cb = cleanup,
        .event_userdata_cb = event,
        .window_title = "PIE",
        .width = 800,
        .height = 600,
        .logger = .{ .func = slog.func },
    });
}
