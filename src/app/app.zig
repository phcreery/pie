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

const pie = @import("pie");
const console = @import("console");
const wgpu = @import("wgpu_dawn");

const gui = @import("gui");
// const window = @import("app_windows.zig");

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
    // window: gui.window.WindowManager = undefined,

    const Self = @This();

    fn init(allocator: std.mem.Allocator, io: std.Io) AppState {
        // const windowmgr = gui.window.WindowManager.init(allocator);

        return .{
            .allocator = allocator,
            .io = io,
            .pass_action = .{},
            .gpu = undefined,
            .gui = undefined, // will init in sokol init fn
            .repo = pie.modules.Repository.init(allocator) catch unreachable,
            // .window = windowmgr,
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

    sg.beginPass(.{ .action = state.pass_action, .swapchain = sglue.swapchain() });

    state.gui.draw();

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

    var repo = try pie.modules.Repository.init(allocator);
    defer repo.deinit();
    state.repo = repo;

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
