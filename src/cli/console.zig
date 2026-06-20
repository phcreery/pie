const builtin = @import("builtin");
const std = @import("std");

// Import necessary windows types, usually provided by the standard library
const UINT = c_uint;
const BOOL = c_int;

// Externally bind the function from kernel32
extern "kernel32" fn SetConsoleOutputCP(wCodePageID: UINT) callconv(.winapi) BOOL;
extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) UINT;

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
            const original = GetConsoleOutputCP();
            _ = SetConsoleOutputCP(65001);
            return .{ .original = original };
        }
        return .{ .original = {} };
    }

    pub fn deinit(self: UTF8ConsoleOutput) void {
        if (builtin.os.tag == .windows) {
            _ = SetConsoleOutputCP(self.original);
        }
    }
};

/// Terminal size dimensions
pub const TermSize = struct {
    /// Terminal width as measured number of characters that fit into a terminal horizontally
    width: u16,
    /// terminal height as measured number of characters that fit into terminal vertically
    height: u16,
};

/// supports windows, linux, macos
///
/// ## example
///
/// ```zig
/// const std = @import("std");
/// const termSize = @import("termSize");
///
/// fn main() !void {
///   std.debug.print(
///     "{any}",
///     termSize.termSize(std.os.getStdOut()),
///   );
/// }
/// ```
pub fn termSize(io: std.Io, file: std.Io.File) !?TermSize {
    if (!try file.supportsAnsiEscapeCodes(io)) {
        return null;
    }
    return switch (builtin.os.tag) {
        .windows => null,
        .linux, .macos => blk: {
            var buf: std.posix.winsize = undefined;
            break :blk switch (std.posix.errno(
                std.posix.system.ioctl(
                    file.handle,
                    std.posix.T.IOCGWINSZ,
                    @intFromPtr(&buf),
                ),
            )) {
                .SUCCESS => TermSize{
                    .width = buf.col,
                    .height = buf.row,
                },
                else => error.IoctlError,
            };
        },
        else => error.Unsupported,
    };
}

test "termSize" {
    std.debug.print("termsize {any}", .{termSize(std.testing.io, std.Io.File.stdout())});
}
