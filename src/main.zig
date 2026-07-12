const std = @import("std");
const builtin = @import("builtin");

// APP
pub const app = @import("app/app.zig");

pub const std_options: std.Options = .{
    .log_level = .debug,
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .gpu, .level = .info },
        .{ .scope = .pipe, .level = .info },
        .{ .scope = .suballocator, .level = .info },
        .{ .scope = .DebugAllocator, .level = .warn },
        // .logFn = customLogFn,
    },
};

pub fn main(init: std.process.Init) !void {
    // Dawn's DynamicLibrary::OpenSystem uses LoadLibraryExW with
    // LOAD_LIBRARY_SEARCH_DEFAULT_DIRS, which requires
    // SetDefaultDllDirectories to be called first. Without it,
    // LoadLibraryEx returns ERROR_INVALID_PARAMETER (87).
    // The MSVC CRT normally calls this during init, but pie.exe is
    // a Zig binary with no MSVC CRT.
    if (builtin.os.tag == .windows) {
        const win32 = std.os.windows;
        const SetDefaultDllDirectories = struct {
            extern "kernel32" fn SetDefaultDllDirectories(flags: u32) callconv(.winapi) win32.BOOL;
        };
        const LOAD_LIBRARY_SEARCH_APPLICATION_DIR: u32 = 0x00000100;
        const LOAD_LIBRARY_SEARCH_SYSTEM32: u32 = 0x00000800;
        const LOAD_LIBRARY_SEARCH_USER_DIRS: u32 = 0x00000400;
        _ = SetDefaultDllDirectories.SetDefaultDllDirectories(
            LOAD_LIBRARY_SEARCH_APPLICATION_DIR |
            LOAD_LIBRARY_SEARCH_SYSTEM32 |
            LOAD_LIBRARY_SEARCH_USER_DIRS,
        );
    }
    try app.run(init);
}

comptime {
    if (builtin.is_test) {
        // std.testing.refAllDecls(@This());
        // _ = @import("foo.zig");
    }
}
