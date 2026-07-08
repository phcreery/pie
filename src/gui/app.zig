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
const wgpu = @import("wgpu_dawn");

const Image = @import("components/image.zig").Image;

const AppState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    // UI
    window: window.WindowManager,

    // sokol
    pass_action: sg.PassAction = .{},
    image: Image = undefined,

    // pie
    gpu: pie.gpu.GPU = undefined,
    pipeline: pie.pipeline.Pipeline = undefined,
    modules: *pie.modules.Repository = undefined,

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

    // init image
    state.image = Image.init();

    // initialize pie pipeline
    const ext_device: wgpu.Device = @ptrCast(@constCast(sg.wgpuDevice().?));
    const ext_queue: wgpu.Queue = @ptrCast(@constCast(sg.wgpuQueue().?));
    state.gpu = pie.gpu.GPU.initExternal(ext_device, ext_queue) catch unreachable;

    const pipeline_config: pie.pipeline.PipelineConfig = .{
        .upload_buffer_size_bytes = 75e6,
        .download_buffer_size_bytes = 75e6,
    };
    state.pipeline = pie.Pipeline.init(state.allocator, state.io, &state.gpu, pipeline_config) catch unreachable;

    // run pipeline and webgpu inject texture
    const texture = build_image(
        state.allocator,
        state.io,
        &state.pipeline,
        state.modules,
    ) catch unreachable;
    std.debug.print("texture: {any}\n", .{texture});
    state.image.createFrom(texture);
}

export fn frame(ptr: ?*anyopaque) void {
    const state: *AppState = @ptrCast(@alignCast(ptr));

    sg.beginPass(.{ .action = state.pass_action, .swapchain = sglue.swapchain() });

    state.image.draw();

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
    repo: *pie.modules.Repository,
) !*pie.gpu.Texture {
    _ = io;

    var arena_instance = std.heap.ArenaAllocator.init(allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const input_filename = "testing/images/DSC_6765.NEF";

    const mod_i_raw = try pipeline.addModuleFromRepo(repo, "i-raw");
    const mod_format = try pipeline.addModuleFromRepo(repo, "format");
    const mod_denoise = try pipeline.addModuleFromRepo(repo, "denoise");
    const mod_demosaic = try pipeline.addModuleFromRepo(repo, "demosaic");
    const mod_crop = try pipeline.addModuleFromRepo(repo, "crop");
    const mod_color = try pipeline.addModuleFromRepo(repo, "color");
    const mod_filmcurv = try pipeline.addModuleFromRepo(repo, "filmcurv");
    const mod_o_display = try pipeline.addModuleFromRepo(repo, "o-display");

    try pipeline.setModuleParam(mod_i_raw, "filename", @as([]const u8, input_filename));
    try pipeline.setModuleParam(mod_i_raw, "wb_mode", @as(i32, 0));
    try pipeline.setModuleParam(mod_color, "wb_tint", @as(f32, 0.0));
    try pipeline.setModuleParam(mod_color, "wb_coeff", [3]f32{ 0.70393723, 1, 1.3611937 }); // from 1/(srgb_from_xyz*xyz_d65_from_cam*(1/wb_cam)) of DSC_6765.NEF
    try pipeline.setModuleParam(mod_filmcurv, "colormode", @as(i32, 1));
    try pipeline.setModuleParam(mod_filmcurv, "brightness", @as(f32, 3.8));
    try pipeline.setModuleParam(mod_filmcurv, "contrast", @as(f32, 1.3));
    try pipeline.setModuleParam(mod_filmcurv, "bias", @as(f32, 0.0));

    try pipeline.connectModules(mod_i_raw, "output", mod_format, "input");
    try pipeline.connectModules(mod_format, "output", mod_denoise, "input");
    try pipeline.connectModules(mod_denoise, "output", mod_demosaic, "input");
    try pipeline.connectModules(mod_demosaic, "output", mod_crop, "input");
    try pipeline.connectModules(mod_crop, "output", mod_color, "input");
    try pipeline.connectModules(mod_color, "output", mod_filmcurv, "input");
    try pipeline.connectModules(mod_filmcurv, "output", mod_o_display, "input");

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
    // const state = try util.allocator.create(AppState);
    // errdefer util.allocator.destroy(state);
    // state.* = AppState.init(util.allocator);

    // Alternatively, allocate the application state on the stack
    const state: *AppState = @constCast(&AppState.init(allocator, io));
    defer state.deinit();

    const cout = console.console.UTF8ConsoleOutput.init();
    defer cout.deinit();

    var modules = try pie.modules.Repository.init(allocator);
    defer modules.deinit();
    state.modules = &modules;

    // var arena_instance = std.heap.ArenaAllocator.init(allocator);
    // defer arena_instance.deinit();
    // const arena = arena_instance.allocator();
    // state.arena = arena;

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
