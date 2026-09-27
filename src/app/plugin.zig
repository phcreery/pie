//! Host-side loader and watcher for the hot-reloadable GUI plugin.
//!
//! The plugin owns nothing, so a reload is just:
//!
//! 1. stage a copy of the freshly built library under a free path (dlopen keys
//!    on the path, so the new generation needs a name no live mapping uses, and
//!    the previous generation keeps running if this one is broken),
//! 2. `dlopen`, resolve the entry points and check the ABI version — any
//!    failure leaves the running GUI untouched,
//! 3. `dlclose` the previous generation.
//!
//! The pipeline, its textures and all view/panel state live in the host
//! (`src/app/session.zig`, `abi.SharedState`), so nothing is saved or restored.

const std = @import("std");
const builtin = @import("builtin");

const sokol = @import("sokol");
const sapp = sokol.app;

const abi = @import("abi");

const log = std.log.scoped(.hotreload);

/// Suffix of the per-generation staged copies, e.g. `libgui.so.gen3`.
const staged_suffix = ".gen";

/// How often the plugin file is stat'ed for changes.
const poll_interval_ns: i96 = 200 * std.time.ns_per_ms;

pub const GuiPlugin = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// host state, so the loader can publish the reload count for the UI
    state: *abi.SharedState,

    /// absolute path of the built plugin
    path: []u8,
    /// path of the staged copy currently mapped, if any
    staged_path: ?[]u8 = null,

    lib: std.DynLib,
    entry: abi.Entry,

    generation: u32 = 0,
    mtime_ns: i96 = 0,
    polled_at_ns: i96 = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, io: std.Io, state: *abi.SharedState) !Self {
        const path = try resolvePath(allocator, io);
        errdefer allocator.free(path);

        // Leftovers from a previous process (the generation counter restarts).
        sweepStaleStages(allocator, io, path);

        var lib = try std.DynLib.open(path);
        errdefer lib.close();
        const entry = try lookupEntry(&lib);

        return .{
            .allocator = allocator,
            .io = io,
            .state = state,
            .path = path,
            .lib = lib,
            .entry = entry,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.staged_path) |staged| {
            std.Io.Dir.deleteFileAbsolute(self.io, staged) catch {};
            self.allocator.free(staged);
        }
        self.lib.close();
        self.allocator.free(self.path);
        self.* = undefined;
    }

    /// Poll the plugin file once per frame and reload it in place when it
    /// changes. MUST be called outside any ImGui frame / render pass.
    pub fn tick(self: *Self) void {
        const now = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
        if (now - self.polled_at_ns < poll_interval_ns) return;
        self.polled_at_ns = now;

        const mtime = self.currentMtime() orelse return;
        if (mtime == self.mtime_ns) return;
        // Record the mtime up front so a broken artifact does not retry every poll.
        self.mtime_ns = mtime;

        self.reload() catch |err| {
            log.err("reload failed, keeping the running GUI: {s}", .{@errorName(err)});
        };
    }

    pub fn draw(self: *Self, state: *abi.SharedState, model: *const abi.Model) void {
        self.entry.draw(state, model);
    }

    pub fn event(self: *Self, state: *abi.SharedState, ev: [*c]const sapp.Event) void {
        self.entry.event(state, ev);
    }

    fn currentMtime(self: *const Self) ?i96 {
        const st = std.Io.Dir.statFile(.cwd(), self.io, self.path, .{}) catch return null;
        return st.mtime.nanoseconds;
    }

    fn reload(self: *Self) !void {
        const started_at = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
        const generation = self.generation + 1;
        const staged = try std.fmt.allocPrint(self.allocator, "{s}{s}{d}", .{ self.path, staged_suffix, generation });
        errdefer self.allocator.free(staged);

        // Atomic copy, so a concurrent `zig build` cannot hand us a torn file.
        _ = try std.Io.Dir.updateFile(.cwd(), self.io, self.path, .cwd(), staged, .{});
        errdefer std.Io.Dir.deleteFileAbsolute(self.io, staged) catch {};

        var lib = try std.DynLib.open(staged);
        errdefer lib.close();
        const entry = try lookupEntry(&lib);

        // Everything from here on cannot fail: swap and drop the old generation.
        const previous_staged = self.staged_path;
        var previous_lib = self.lib;

        self.lib = lib;
        self.entry = entry;
        self.generation = generation;
        self.staged_path = staged;

        previous_lib.close();
        if (previous_staged) |path| {
            std.Io.Dir.deleteFileAbsolute(self.io, path) catch {};
            self.allocator.free(path);
        }

        self.state.reloads += 1;
        const elapsed_ms = @divTrunc(std.Io.Timestamp.now(self.io, .awake).nanoseconds - started_at, std.time.ns_per_ms);
        log.info("reloaded GUI plugin -> generation {d} in {d} ms", .{ generation, elapsed_ms });
    }
};

fn lookupEntry(lib: *std.DynLib) !abi.Entry {
    const entry: abi.Entry = .{
        .version = lib.lookup(*const abi.Entry.VersionFn, "gui_abi_version") orelse return missingSymbol("gui_abi_version"),
        .layout = lib.lookup(*const abi.Entry.LayoutFn, "gui_abi_layout") orelse return missingSymbol("gui_abi_layout"),
        .draw = lib.lookup(*const abi.Entry.DrawFn, "gui_draw") orelse return missingSymbol("gui_draw"),
        .event = lib.lookup(*const abi.Entry.EventFn, "gui_event") orelse return missingSymbol("gui_event"),
    };

    // A plugin built against a different `src/abi/root.zig` would reinterpret
    // the model/state structs, so refuse it.
    const version = entry.version();
    if (version != abi.abi_version) {
        log.err("GUI plugin has ABI version {d}, the app expects {d} — rebuild and restart the app", .{
            version, abi.abi_version,
        });
        return error.AbiVersionMismatch;
    }

    // The version alone is not enough now that `types/ui.zig` is shared: editing
    // the vocabulary and rebuilding only the plugin would keep the version and
    // change the layout.
    const layout = entry.layout();
    if (layout != abi.layout_hash) {
        log.err("GUI plugin layout {x} does not match the app's {x} — the shared types changed; rebuild and restart the app", .{
            layout, abi.layout_hash,
        });
        return error.AbiLayoutMismatch;
    }
    return entry;
}

fn missingSymbol(comptime name: []const u8) error{MissingSymbol} {
    log.err("GUI plugin is missing export '{s}'", .{name});
    return error.MissingSymbol;
}

/// Resolve the built plugin. Prefer the executable-relative location
/// (`zig-out/lib`) so the binary can be launched from anywhere; fall back to
/// the path `zig build app` runs from (the project root).
fn resolvePath(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    if (builtin.os.tag == .linux) {
        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        if (std.Io.Dir.readLinkAbsolute(io, "/proc/self/exe", &buffer)) |len| {
            if (std.fs.path.dirname(buffer[0..len])) |exe_dir| {
                return std.fs.path.join(allocator, &.{ exe_dir, "..", "lib", abi.plugin_file_name });
            }
        } else |err| {
            log.warn("could not resolve /proc/self/exe ({s})", .{@errorName(err)});
        }
    }
    return std.fs.path.join(allocator, &.{ "zig-out", "lib", abi.plugin_file_name });
}

/// Delete `libgui.so.gen*` files left behind by a previous run.
fn sweepStaleStages(allocator: std.mem.Allocator, io: std.Io, plugin_path: []const u8) void {
    const dir_path = std.fs.path.dirname(plugin_path) orelse return;
    const prefix = std.fs.path.basename(plugin_path);

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        log.warn("could not scan '{s}' for stale staged plugins: {s}", .{ dir_path, @errorName(err) });
        return;
    };
    defer dir.close(io);

    var iterator = std.Io.Dir.iterate(dir);
    while (iterator.next(io) catch null) |entry| {
        if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
        if (std.mem.indexOf(u8, entry.name, staged_suffix) == null) continue;

        const stale = std.fs.path.join(allocator, &.{ dir_path, entry.name }) catch continue;
        defer allocator.free(stale);
        std.Io.Dir.deleteFileAbsolute(io, stale) catch {};
        log.debug("removed stale staged plugin '{s}'", .{stale});
    }
}
