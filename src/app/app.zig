const std = @import("std");

const sokol = @import("sokol");
const slog = sokol.log;
const sg = sokol.gfx;
const sapp = sokol.app;
const sglue = sokol.glue;
const cui = @import("cui");
const CuiRenderer = @import("cui_sokol").Renderer;
const cui_input = @import("cui_input.zig");

const pie = @import("pie");
const console = @import("console");
const wgpu = @import("wgpu_zig");

const session = @import("session");
const Session = session.Session;
const gui = @import("gui");
const GUI = gui.GUI;

const util = @import("../mem.zig");

// God Object for app state.
//
// The app owns the window and sokol/ImGui contexts, the WebGPU device, the
// editing session (pipeline + textures + catalog + blit) and the GUI's view
// state.
pub const AppState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// thumbnail cache directory (owned)
    cache_dir: []u8,
    /// print the pipeline performance report after every run (`--perf`)
    perf_report: bool = false,

    // sokol
    pass_action: sg.PassAction,

    // pie
    gpu: pie.gpu.GPU,

    // editing session (pipeline + display texture + catalog)
    session: Session,
    // editor widgets
    gui: GUI,

    // CUI
    ui: ?*cui.cui_ctx = null,
    ui_renderer: CuiRenderer = undefined,
    last_cursor: cui.cui_cursor = std.math.maxInt(cui.cui_cursor),

    const Self = @This();

    fn init(allocator: std.mem.Allocator, io: std.Io, cache_dir: []u8, perf_report: bool) Self {
        return .{
            .allocator = allocator,
            .io = io,
            .cache_dir = cache_dir,
            .perf_report = perf_report,
            .pass_action = .{},
            // initted in the sokol callbacks below
            .gpu = undefined,
            .session = undefined,
            .gui = undefined,
        };
    }
};

export fn init_fn(ptr: ?*anyopaque) void {
    const state: *AppState = @ptrCast(@alignCast(ptr));

    // initialize sokol-gfx
    sg.setup(.{
        .environment = sglue.environment(),
        .logger = .{ .func = slog.func },
    });

    // CUI owns the UI; this app owns the window and the sokol render pass.
    var ctx_desc = std.mem.zeroes(cui.cui_ctx_desc);
    ctx_desc.theme = @intCast(cui.CUI_THEME_DARK);
    ctx_desc.accent = @intCast(cui.CUI_ACCENT_NEUTRAL);
    state.ui_renderer = CuiRenderer.init(state.allocator) catch unreachable;
    ctx_desc.renderer = state.ui_renderer.iface();
    state.ui = cui.cui_create(&ctx_desc) orelse unreachable;
    gui.theme.apply(state.ui.?);
    cui.cui_set_platform(state.ui.?, &platform_iface);
    cui.cui_input_focus(state.ui.?, true);

    // initial clear color
    state.pass_action.colors[0] = .{
        .load_action = .CLEAR,
        // 18% Reflective Gray
        .clear_value = .{ .r = 0.462, .g = 0.462, .b = 0.462, .a = 1.0 },
    };

    // initialize pie pipeline
    const ext_device = wgpu.Device{ .device = @ptrCast(@constCast(sg.wgpuDevice().?)) };
    const ext_queue = wgpu.Queue{ .queue = @ptrCast(@constCast(sg.wgpuQueue().?)) };
    state.gpu = pie.GPU.initExternal(state.allocator, state.io, ext_device, ext_queue) catch unreachable;

    // editing session (pipeline + display texture + catalog) and the GUI
    state.session = Session.init(state.allocator, state.io, &state.gpu, state.cache_dir, state.perf_report) catch unreachable;
    state.gui = GUI.init(state.allocator, state.io) catch |err| {
        std.log.err("failed to init the GUI: {s}", .{@errorName(err)});
        unreachable;
    };
}

export fn frame(ptr: ?*anyopaque) void {
    const state: *AppState = @ptrCast(@alignCast(ptr));

    // Move catalog thumbnails along (uploads happen on this thread), then build
    // the graph once and re-run the editor pipeline if a parameter changed in
    // the previous frame. All of that submits GPU work, which is only legal
    // before the render pass starts.
    state.session.tick();
    if (state.session.ensureBuilt()) {
        if (state.session.consumeRun()) {
            state.session.run() catch |err| {
                std.log.err("pipeline re-run failed: {s}", .{@errorName(err)});
            };
        }
    }

    const dpi = sapp.dpiScale();
    cui.cui_set_viewport(state.ui.?, sapp.widthf() / dpi, sapp.heightf() / dpi, dpi);
    cui.cui_begin_frame(state.ui.?, @floatCast(sapp.frameDuration()));
    state.gui.draw(&state.session, state.ui.?, &state.ui_renderer);
    cui.cui_end_frame(state.ui.?);

    const draw_data = cui.cui_get_draw_data(state.ui.?);

    state.ui_renderer.flushTextures();
    state.ui_renderer.prepare(draw_data);

    const cursor = cui.cui_get_cursor(state.ui.?);
    if (cursor != state.last_cursor) {
        state.last_cursor = cursor;
        cui_input.setCursor(cursor);
    }

    if (draw_data != null) {
        const clear = draw_data.*.clear_color;
        state.pass_action.colors[0].clear_value = .{
            .r = @as(f32, @floatFromInt(clear.r)) / 255.0,
            .g = @as(f32, @floatFromInt(clear.g)) / 255.0,
            .b = @as(f32, @floatFromInt(clear.b)) / 255.0,
            .a = @as(f32, @floatFromInt(clear.a)) / 255.0,
        };
    }

    sg.beginPass(.{ .action = state.pass_action, .swapchain = sglue.swapchain() });
    state.ui_renderer.render(draw_data);
    sg.endPass();
    sg.commit();
}

export fn cleanup(ptr: ?*anyopaque) void {
    const state: *AppState = @ptrCast(@alignCast(ptr));
    state.gui.deinit();
    if (state.ui) |ui| cui.cui_destroy(ui);
    state.ui_renderer.deinit();
    state.session.deinit();
    state.gpu.deinit();
    sg.shutdown();
}

export fn event(ev: [*c]const sapp.Event, ptr: ?*anyopaque) void {
    const state: *AppState = @ptrCast(@alignCast(ptr));
    if (ev == null) return;
    if (state.ui) |ui| cui_input.handle(ui, ev.*);
}

const platform_iface = cui.cui_platform_iface{
    .user = null,
    .set_clipboard = setClipboard,
    .get_clipboard = getClipboard,
    .set_cursor = setCursor,
    .set_text_input_rect = null,
    .draw_emoji = null,
};

fn setClipboard(_: ?*anyopaque, utf8: [*c]const u8) callconv(.c) void {
    if (utf8 == null) return;
    sapp.setClipboardString(std.mem.span(utf8));
}

fn getClipboard(_: ?*anyopaque) callconv(.c) [*c]const u8 {
    return sapp.getClipboardString().ptr;
}

fn setCursor(_: ?*anyopaque, cursor: cui.cui_cursor) callconv(.c) void {
    cui_input.setCursor(cursor);
}

pub fn run(init: std.process.Init) !void {
    // general purpose allocator for temporary heap allocations:
    const allocator = util.allocator;
    // default Io implementation:
    const io = init.io;

    var perf_report = false;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next(); // program name
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--perf")) {
            perf_report = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print(
                \\usage: pie [--perf]
                \\  --perf  print the pipeline performance report after every run
                \\
            , .{});
            return;
        } else {
            std.log.warn("ignoring unknown argument '{s}' (try --help)", .{arg});
        }
    }

    // thumbnail cache lives under the user cache dir; keep it for the process
    const cache_dir = session.resolveCacheDir(allocator, init.environ_map) catch
        allocator.dupe(u8, ".pie-thumbs") catch unreachable;
    defer allocator.free(cache_dir);

    // Must outlive `sapp.run`: it is passed as user data to every callback.
    var state: AppState = AppState.init(allocator, io, cache_dir, perf_report);

    const cout = console.console.UTF8ConsoleOutput.init();
    defer cout.deinit();

    sapp.run(.{
        .user_data = &state,
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
