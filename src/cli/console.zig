const builtin = @import("builtin");
const std = @import("std");
pub const termsize = @import("termsize");

/// UTF8ConsoleOutput sets the console output to UTF-8 on Windows
/// and restores the original code page on deinit.
///
/// USE:
/// const cp_out = UTF8ConsoleOutput.init();
/// defer cp_out.deinit();
///
/// https://github.com/ziglang/zig/issues/18229
pub const UTF8ConsoleOutput = struct {
    original: if (builtin.os.tag == .windows) c_uint else void,

    pub fn init() UTF8ConsoleOutput {
        if (builtin.os.tag == .windows) {
            const original = std.os.windows.kernel32.GetConsoleOutputCP();
            _ = std.os.windows.kernel32.SetConsoleOutputCP(65001);
            return .{ .original = original };
        }
        return .{ .original = {} };
    }

    pub fn deinit(self: UTF8ConsoleOutput) void {
        if (builtin.os.tag == .windows) {
            _ = std.os.windows.kernel32.SetConsoleOutputCP(self.original);
        }
    }
};
