const std = @import("std");
const ig = @import("cimgui");
const pretty = @import("pretty");
const util = @import("util.zig");
const builtin = @import("builtin");

const build = @import("build_options");
const print = @import("std").debug.print;

// https://www.openmymind.net/Zig-Interfaces/
// https://medium.com/@jerrythomas_in/exploring-compile-time-interfaces-in-zig-5c1a1a9e59fd
/// IIgWindow is an interface for rendering an ImGui window.
/// It is recommended to use a heap allocated struct as the context.
pub const IIgWindow = struct {
    ptr: *anyopaque,
    impl: *const Interface,

    pub const Interface = struct {
        renderFn: *const fn (ptr: *anyopaque) void,
        destroyFn: *const fn (ptr: *anyopaque) void,
    };

    pub fn render(self: IIgWindow) void {
        return self.impl.renderFn(self.ptr);
    }

    pub fn destroy(self: IIgWindow) void {
        return self.impl.destroyFn(self.ptr);
    }

    // This is new
    pub fn from(ptr: anytype) IIgWindow {
        const T = @TypeOf(ptr);
        const ptr_info = @typeInfo(T);

        if (ptr_info != .pointer) @compileError("ptr must be a pointer");
        if (ptr_info.pointer.size != .One) @compileError("ptr must be a single item pointer");

        const gen = struct {
            pub fn render(pointer: *anyopaque) void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.render(self);
            }
            pub fn destroy(pointer: *anyopaque) void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.destroy(self);
            }
        };

        return .{
            .ptr = ptr,
            .impl = &.{ .renderFn = gen.render, .destroyFn = gen.destroy },
        };
    }
};

pub const About = struct {
    allocator: std.mem.Allocator,
    is_open: bool,
    pos: ig.ImVec2,
    size: ig.ImVec2,
    cimgui_version: []const u8,
    // libraw_version: string = libraw.libraw_version().ostr,

    fn render(self: *About) void {
        // std.debug.print("About.render self\n", .{});
        // pretty.print(util.gpa, self, .{}) catch unreachable;
        // std.process.exit(1);

        if (!self.is_open) {
            return;
        }

        ig.igSetNextWindowPosEx(self.pos, ig.ImGuiCond_Once, ig.ImVec2{ .x = 0, .y = 0 });
        ig.igSetNextWindowSize(self.size, ig.ImGuiCond_Once);
        // ig.igSetNextWindowCollapsed(true, ig.ImGuiCond_Once);

        _ = ig.igBegin("About", &self.is_open, ig.ImGuiWindowFlags_None);
        ig.igText("PIE: Peyton's Image Editor v0.0.0");

        const zig_version_text = std.fmt.allocPrintZ(util.gpa, "zig version: {s}", .{builtin.zig_version_string}) catch unreachable;
        ig.igText(zig_version_text.ptr);

        // https://ziggit.dev/t/equivalent-of-cs-date-and-time-macros/2076/2
        const build_time_text = std.fmt.allocPrintZ(util.gpa, "build date: {}", .{build.timestamp}) catch unreachable;
        ig.igText(build_time_text.ptr);

        // https://ziggit.dev/t/how-to-return-a-c-string-from-u8/4569/2
        const cimgui_version_text = std.fmt.allocPrintZ(util.gpa, "cimgui version: {s}", .{self.cimgui_version}) catch unreachable;
        ig.igText(cimgui_version_text.ptr);

        // ig.igText(std.fmt("LibRaw version: {}", self.libraw_version));

        // for backend in state.center_image_pixpipe.backends {
        //     ig.igText(std.fmt("Backend: {} {}", backend.name, backend.version));
        //     if (backend is cl.BackendCL) {
        //         ig.igText(std.fmt(" - {}", backend.device.*));
        //     }
        // }

        ig.igText("");
        ig.igText("Main Thread:");
        // ig.igText(std.fmt("FPS: {} ({}|{})", state.fg.fps, state.fg.fps_max(), state.fg.fps_min()));
        // ig.igPlotLinesFloatPtr("FPS", state.fg.fps_history.data, 100, 0, "", 0, 120, ig.ImVec2{ .x = 0, .y = 80 }, @sizeOf(f32));
        // ig.igText(std.fmt("Duty cycle: {}%%", state.fg.duty_cycle * 100));
        // ig.igPlotLinesFloatPtr("Duty cycle", state.fg.duty_history.data, 100, 0, "", 0, 1, ig.ImVec2{ .x = 0, .y = 80 }, @sizeOf(f32));

        ig.igEnd();
    }

    // pub fn new() *About {
    //     const about = &About{};
    //     return about;
    // }

    pub fn init(self: *About, allocator: std.mem.Allocator) void {
        self.* = .{
            .allocator = allocator,
            .is_open = true,
            .pos = ig.ImVec2{ .x = 10, .y = 10 },
            .size = ig.ImVec2{ .x = 300, .y = 400 },
            // https://stackoverflow.com/questions/72736997/how-to-pass-a-c-string-into-a-zig-function-expecting-a-zig-string
            // https://dev.to/jmatth11/quick-zig-and-c-string-conversion-conundrums-203b
            .cimgui_version = std.mem.span(ig.igGetVersion())[0..],
        };
    }

    /// Allocates and initializes an About struct.
    pub fn create(allocator: std.mem.Allocator) *About {
        const result = allocator.create(About) catch unreachable;
        errdefer allocator.destroy(result);

        result.init(allocator);
        return result;
    }

    pub fn destroy(self: *About) void {
        // Free the resources
        self.allocator.destroy(self);
    }
};
