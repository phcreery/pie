//! Native folder chooser, backed by nativefiledialog-extended.
//!
//! The `nfd` C library is built by the `nativefiledialog_extended` package and
//! linked into this module (see `build.zig`). That package ships the headers and
//! the build glue but no Zig bindings, and only the single-folder picker is
//! needed, so the C entry points are declared here rather than pulled in through
//! `@cImport`. The `U8` variants are UTF-8 on every platform (`N` variants alias
//! to UTF-16 on Windows).
//!
//! The dialog is modal and blocks the calling thread, so it must be opened from
//! the main thread and outside the render pass (see `Session.tick`).

const std = @import("std");

const slog = std.log.scoped(.nfd);

extern fn NFD_Init() c_int;
extern fn NFD_Quit() void;
extern fn NFD_PickFolderU8(out_path: *?[*:0]u8, default_path: ?[*:0]const u8) c_int;
extern fn NFD_FreePathU8(path: ?[*:0]u8) void;
extern fn NFD_GetError() ?[*:0]const u8;

/// `nfdresult_t`
const NFD_OKAY: c_int = 1;
const NFD_CANCEL: c_int = 2;

var initialized = false;

/// Release the platform resources NFD took in `init`. Safe to call uninitialized.
pub fn deinit() void {
    if (!initialized) return;
    NFD_Quit();
    initialized = false;
}

/// Ask the user for a folder. `default_path` seeds the dialog's location.
/// Returns an owned UTF-8 path, or null if the user cancelled or the platform
/// refused to open a dialog (already logged).
pub fn pickFolder(allocator: std.mem.Allocator, default_path: ?[]const u8) ?[]u8 {
    if (!ensureInit()) return null;

    const default_z = if (default_path) |path| allocator.dupeSentinel(u8, path, 0) catch null else null;
    defer if (default_z) |z| allocator.free(z);

    var out: ?[*:0]u8 = null;
    switch (NFD_PickFolderU8(&out, if (default_z) |z| z.ptr else null)) {
        NFD_OKAY => {},
        NFD_CANCEL => return null,
        else => {
            slog.err("cannot open a folder dialog: {s}", .{lastError()});
            return null;
        },
    }

    const raw = out orelse return null;
    defer NFD_FreePathU8(raw);
    return allocator.dupe(u8, std.mem.span(raw)) catch null;
}

fn ensureInit() bool {
    if (initialized) return true;
    if (NFD_Init() != NFD_OKAY) {
        slog.err("cannot initialize the folder chooser: {s}", .{lastError()});
        return false;
    }
    initialized = true;
    return true;
}

fn lastError() []const u8 {
    const message = NFD_GetError() orelse return "unknown error";
    return std.mem.span(message);
}
