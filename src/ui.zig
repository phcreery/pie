const std = @import("std");
const ig = @import("cimgui");
const pretty = @import("pretty");
const util = @import("util.zig");

// https://www.openmymind.net/Zig-Interfaces/
// https://medium.com/@jerrythomas_in/exploring-compile-time-interfaces-in-zig-5c1a1a9e59fd
pub const IIgWindow = struct {
    ptr: *anyopaque,
    renderFn: *const fn (ptr: *anyopaque) void,

    pub fn render(self: IIgWindow) void {
        return self.renderFn(self.ptr);
    }

    // pub fn from(ctx: *anyopaque, comptime T: type) IIgWindow {
    //     const self: *T = @ptrCast(@alignCast(ctx));
    //     return .{
    //         .ptr = self,
    //         // .impl = &.{ .area = T.area },
    //         .renderFn = T.render,
    //     };
    // }
};

pub const About = struct {
    is_open: bool,
    pos: ig.ImVec2,
    size: ig.ImVec2,
    cimgui_version: [:0]const u8,
    // libraw_version: string = libraw.libraw_version().ostr,

    fn render(ptr: *anyopaque) void {
        // This re-establishs the type: *anyopaque -> *File
        const self: *About = @ptrCast(@alignCast(ptr));
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
        // ig.igText(std.fmt("v hash: {}", @VHASH));
        // ig.igText(std.fmt("build date: {} {}", @BUILD_DATE, @BUILD_TIME));
        // const version_text = std.fmt("cimgui version: {}", self.cimgui_version);

        // var version_text: [256]u8 = undefined;
        // const version_text2 = std.fmt.bufPrint(&version_text, "cimgui version: {s}", .{self.cimgui_version}) catch unreachable;
        // ig.igText(version_text2[0.. :0]);

        // https://ziggit.dev/t/how-to-return-a-c-string-from-u8/4569/11
        const str = std.fmt.allocPrint(util.gpa, "cimgui version: {s}", .{self.cimgui_version[0..]}) catch unreachable;
        const c_str = util.gpa.dupeZ(u8, str) catch unreachable;
        defer util.gpa.free(c_str);
        ig.igText(c_str);

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

    pub fn init() About {
        return .{
            .is_open = true,
            .pos = ig.ImVec2{ .x = 10, .y = 10 },
            .size = ig.ImVec2{ .x = 300, .y = 400 },
            // https://stackoverflow.com/questions/72736997/how-to-pass-a-c-string-into-a-zig-function-expecting-a-zig-string
            .cimgui_version = std.mem.span(ig.igGetVersion()),
        };
    }

    pub fn imguiWindow(self: *About) IIgWindow {
        // std.debug.print("About.imguiWindow self\n", .{});
        // pretty.print(util.gpa, self, .{}) catch unreachable;
        return .{
            // this "erases" the type: *About -> *anyopaque
            .ptr = self,
            .renderFn = render,
        };
    }
};
