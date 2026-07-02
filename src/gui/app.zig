const ig = @import("cimgui");
const sokol = @import("sokol");
const slog = sokol.log;
const sg = sokol.gfx;
const sapp = sokol.app;
const sglue = sokol.glue;
const simgui = sokol.imgui;
const std = @import("std");
const util = @import("../mem.zig");
const builtin = @import("builtin");

const window = @import("window.zig");
const pie = @import("pie");

const AppState = struct {
    pass_action: sg.PassAction = .{},
    window: window.WindowManager,

    const Self = @This();

    fn init(allocator: std.mem.Allocator) AppState {
        const windowmgr = window.WindowManager.init(allocator);

        return .{
            .pass_action = .{},
            .window = windowmgr,
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
export fn init(ptr: ?*anyopaque) void {
    const state: *AppState = @ptrCast(@alignCast(ptr));

    // initialize sokol-gfx
    sg.setup(.{
        .environment = sglue.environment(),
        .logger = .{ .func = slog.func },
    });
    // initialize sokol-imgui
    simgui.setup(.{
        .logger = .{ .func = slog.func },
    });

    // initial clear color
    state.pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{ .r = 0.05, .g = 0.5, .b = 1.0, .a = 1.0 },
    };
}

export fn frame(ptr: ?*anyopaque) void {
    const state: *AppState = @ptrCast(@alignCast(ptr));

    // call simgui.newFrame() before any ImGui calls
    simgui.newFrame(.{
        .width = sapp.width(),
        .height = sapp.height(),
        .delta_time = sapp.frameDuration(),
        .dpi_scale = sapp.dpiScale(),
    });

    // === UI CODE STARTS HERE

    ig.igSetNextWindowPos(.{ .x = 10, .y = 10 }, ig.ImGuiCond_Once);
    ig.igSetNextWindowSize(.{ .x = 400, .y = 100 }, ig.ImGuiCond_Once);
    _ = ig.igBegin("Hello Dear ImGui!", 0, ig.ImGuiWindowFlags_None);
    _ = ig.igColorEdit3("Background", &state.pass_action.colors[0].clear_value.r, ig.ImGuiColorEditFlags_None);
    ig.igEnd();

    // std.debug.print("frame state\n", .{});
    // std.debug.print("{any}\n", .{state});

    state.window.render();

    // === UI CODE ENDS HERE

    // call simgui.render() inside a sokol-gfx pass
    sg.beginPass(.{ .action = state.pass_action, .swapchain = sglue.swapchain() });
    simgui.render();
    sg.endPass();
    sg.commit();
}

export fn cleanup(ptr: ?*anyopaque) void {
    const state: *AppState = @ptrCast(@alignCast(ptr));
    _ = state;
    simgui.shutdown();
    sg.shutdown();
}

export fn event(ev: [*c]const sapp.Event, ptr: ?*anyopaque) void {
    const state: *AppState = @ptrCast(@alignCast(ptr));
    _ = state;
    // forward input events to sokol-imgui
    _ = simgui.handleEvent(ev.*);
}

fn build_image(allocator: *std.mem.Allocator, io: std.Io) void {
    const cout = pie.cli.console.UTF8ConsoleOutput.init();
    defer cout.deinit();

    var gpu_instance = try pie.gpu.GPU.init(io);
    defer gpu_instance.deinit();

    var modules = try pie.modules.Registry.init(allocator);
    defer modules.deinit();

    var arena_instance = std.heap.ArenaAllocator.init(allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const pipeline_config: pie.pipeline.PipelineConfig = .{
        .upload_buffer_size_bytes = 75e6,
        .download_buffer_size_bytes = 75e6,
    };

    var pipeline = pie.Pipeline.init(allocator, io, &gpu_instance, pipeline_config) catch unreachable;
    defer pipeline.deinit();

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
}

pub fn run() void {
    // Allocate the application state on the heap to ensure it lives long enough.
    // const state = util.allocator.create(AppState) catch unreachable;
    // errdefer util.allocator.destroy(state);
    // state.* = AppState.init(util.allocator);

    // Alternatively, allocate the application state on the stack
    const state: *AppState = @constCast(&AppState.init(util.allocator));
    defer state.deinit();

    sapp.run(.{
        .user_data = state,
        .init_userdata_cb = init,
        .frame_userdata_cb = frame,
        .cleanup_userdata_cb = cleanup,
        .event_userdata_cb = event,
        .window_title = "PIE",
        .width = 800,
        .height = 600,
        .logger = .{ .func = slog.func },
    });
}
