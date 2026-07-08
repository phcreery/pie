const std = @import("std");
const builtin = @import("builtin");

const ig = @import("cimgui");
const sokol = @import("sokol");
const slog = sokol.log;
const sg = sokol.gfx;
const sapp = sokol.app;
const sglue = sokol.glue;
// const simgui = sokol.imgui;
const zr = @import("zr");

const pie = @import("pie");
const console = @import("console");
const wgpu = @import("wgpu_dawn");

const gui = @import("gui");

// const window = @import("app_windows.zig");
const util = @import("../mem.zig");

// Configured plugin type. This will hold the symbols we wish to hot-reload.
const PluginGUI = zr.Plugin(@import("gui"), .{
    .name = "gui",
    .link_mode = .dynamic,
    // An override to the subpath (relative to file executable directory) where the plugin's dynamic library is located in.
    //
    // If `null`, this is `./` on windows and `../lib/` everywhere else.
    .load_path_override = null,
    // Contains the list of symbols that will be hot-reloaded.
    //
    // These need to be actual symbols in the `"plugin"` module we imported before.
    // They are the "single source of truth" and the types will be fetched from them.
    //
    // These symbols need to be exported with `@export`, and if they are functions,
    // they need to be `callconv(.c)`.
    .syms = &.{
        "gui_update",
        "gui_draw",
    },
});

// God Object for app state
pub const AppState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    // sokol
    pass_action: sg.PassAction,

    // pie
    gpu: pie.gpu.GPU,
    repo: pie.modules.Repository,

    // app
    // these are initted and deinitted in the sokol calls
    gui: gui.GUI,

    // hot relaod
    plugin_gui: PluginGUI,
    // gui_draw: @TypeOf(gui.gui_draw),
    // gui_draw: *anytype,
    gui_update: *fn (*gui.GUI) callconv(.c) void,
    gui_draw: *fn (*gui.GUI) callconv(.c) void,

    const Self = @This();

    fn init(allocator: std.mem.Allocator, io: std.Io) AppState {
        // const windowmgr = gui.window.WindowManager.init(allocator);

        return .{
            .allocator = allocator,
            .io = io,
            .pass_action = .{},
            .gpu = undefined,
            .gui = undefined, // will init in sokol init fn
            .repo = undefined, // assigned in run()
            // .window = windowmgr,
            .plugin_gui = undefined,
            .gui_update = undefined,
            .gui_draw = undefined,
        };
    }

    fn deinit(self: *Self) void {
        self.repo.deinit();
    }
};

export fn init_fn(ptr: ?*anyopaque) void {
    std.debug.print("init_fn called with ptr: {any}\n", .{ptr});
    var state: *AppState = @ptrCast(@alignCast(ptr));

    // initialize sokol-gfx
    sg.setup(.{
        .environment = sglue.environment(),
        .logger = .{ .func = slog.func },
    });

    // initial clear color
    state.pass_action.colors[0] = .{
        .load_action = .CLEAR,
        // 18% Reflective Gray
        .clear_value = .{ .r = 0.462, .g = 0.462, .b = 0.462, .a = 1.0 },
    };

    // initialize pie pipeline
    const ext_device: wgpu.Device = @ptrCast(@constCast(sg.wgpuDevice().?));
    const ext_queue: wgpu.Queue = @ptrCast(@constCast(sg.wgpuQueue().?));
    state.gpu = pie.GPU.initExternal(ext_device, ext_queue) catch unreachable;
    // state.pipeline = pie.Pipeline.init(state.allocator, state.io, &state.gpu, null) catch unreachable;
    state.gui = .init(state.allocator, state.io, &state.gpu, &state.repo);
}

export fn frame(ptr: ?*anyopaque) void {
    const state: *AppState = @ptrCast(@alignCast(ptr));

    // Run logic + compute (may submit to the WebGPU queue) BEFORE the render
    // pass: Dawn disallows buffer mapAsync/queue.submit while a render command
    // encoder is open ("Concurrent buffer operations are not allowed").
    state.gui_update(&state.gui);

    sg.beginPass(.{ .action = state.pass_action, .swapchain = sglue.swapchain() });

    // Render only.
    // state.gui.draw();
    state.gui_draw(&state.gui);

    sg.endPass();
    sg.commit();
}

export fn cleanup(ptr: ?*anyopaque) void {
    const state: *AppState = @ptrCast(@alignCast(ptr));
    state.gui.deinit();
    state.gpu.deinit();
    sg.shutdown();
}

export fn event(ev: [*c]const sapp.Event, ptr: ?*anyopaque) void {
    const state: *AppState = @ptrCast(@alignCast(ptr));
    state.gui.event(ev);
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

    const repo = try pie.modules.Repository.init(allocator);
    state.repo = repo;

    // Use preferably a dynamic allocator for a plugin, rather than a `FixedBufferAllocator` or an `ArenaAllocator`,
    // since it holds mainly array lists inside.
    var plugin_gui = try PluginGUI.new(io, allocator);
    defer plugin_gui.destroy();
    state.plugin_gui = plugin_gui;

    state.gui_update = @constCast(plugin_gui.symbol("gui_update"));
    state.gui_draw = @constCast(plugin_gui.symbol("gui_draw"));

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
