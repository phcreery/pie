//! Recommended default pipelines, keyed by input file type.

const std = @import("std");
const api = @import("modules/api.zig");
const pipeline = @import("pipeline.zig");
const serdes = @import("serdes.zig");

pub const Format = struct {
    /// The `i-*` module that reads the file; also identifies the family and
    /// names its asset, `assets/default.<source_module>.graph`.
    source_module: []const u8,
    /// File extensions this family claims, without the leading dot.
    extensions: []const []const u8,
    graph: []const u8,
};

/// Every input family the engine decodes.
const formats = [_]Format{
    .{
        .source_module = "i-raw",
        .extensions = &.{
            "nef", "cr2", "cr3", "arw", "dng", "raf", "rw2", "orf", "pef", "srw", "nrw", "raw",
        },
        .graph = @embedFile("default.i-raw.graph"),
    },
    .{
        .source_module = "i-png",
        .extensions = &.{"png"},
        .graph = @embedFile("default.i-png.graph"),
    },
};

/// The family that decodes `path`, judged from its extension alone; null when
/// no `i-*` module claims it.
pub fn formatForPath(path: []const u8) ?*const Format {
    const ext = std.fs.path.extension(path);
    if (ext.len < 2) return null;
    const bare = ext[1..]; // skip the dot
    for (&formats) |*format| {
        for (format.extensions) |candidate| {
            if (std.ascii.eqlIgnoreCase(bare, candidate)) return format;
        }
    }
    return null;
}

pub const Options = struct {
    /// When set, a `downscale` module caps the longest edge of the output. The
    /// editor passes null (full resolution); the thumbnail decoder passes the
    /// catalog's thumbnail size.
    max_edge: ?u32 = null,
    /// When set, the graph ends in a file sink writing to this path instead of
    /// its `o-display` sink. The thumbnail decoder uses this to render into its
    /// on-disk cache.
    output_path: ?[]const u8 = null,
    /// File sink module used for `output_path`. Any `o-*` module with an
    /// rgba16float input and a `filename` param works (`o-png`, `o-qoi`, ...).
    output_module: []const u8 = "o-png",
};

/// The endpoints of a recommended graph. `sink` is the asset's `o-display`
/// sink unless `Options.output_path` asked for a file sink; callers that render
/// repeatedly can re-point the sink's `filename` param without rebuilding the
/// graph.
pub const Graph = struct {
    source: pipeline.ModuleHandle,
    sink: pipeline.ModuleHandle,
};

/// Build the recommended pipeline for `path` and point its source at the file.
pub fn recommend(
    pipe: *pipeline.Pipeline,
    path: []const u8,
    options: Options,
) !void {
    const format = formatForPath(path) orelse return error.UnsupportedFileType;
    const graph = try recommendFormat(pipe, format, options);
    try pipe.setModuleParam(graph.source, "filename", []const u8, path);
    return;
}

pub fn recommendFormat(
    pipe: *pipeline.Pipeline,
    format: *const Format,
    options: Options,
) !Graph {
    try serdes.deserialize(pipe, format.graph);

    var sources = try pipe.modulesOfType(.source);
    defer sources.deinit(pipe.allocator);
    var sinks = try pipe.modulesOfType(.sink);
    defer sinks.deinit(pipe.allocator);
    if (sources.items.len == 0 or sinks.items.len == 0) return error.GraphModuleMissing;

    const source = sources.items[0];
    var sink = sinks.items[0];

    if (options.output_path == null and options.max_edge == null) {
        return .{ .source = source, .sink = sink };
    }

    var tail = try upstream(pipe, sink);
    if (options.max_edge) |max_edge| {
        tail = try appendDownscale(pipe, tail, max_edge);
    }

    if (options.output_path != null) {
        // swap the current sink with the output module
        const display_module_handle = try pipe.module_pool.getPtr(sink);
        try pipe.removeModuleByNameNoRecord(display_module_handle.name, display_module_handle.id);
        sink = try pipe.addModuleNoRecord("01", options.output_module);
    }

    try pipe.connectModulesNoRecord(tail.module, tail.socket, sink, "input");
    if (options.output_path) |path| {
        try pipe.setModuleParam(sink, "filename", []const u8, path);
    }
    return .{ .source = source, .sink = sink };
}

const Link = struct {
    module: pipeline.ModuleHandle,
    socket: []const u8,
};

fn upstream(pipe: *pipeline.Pipeline, handle: pipeline.ModuleHandle) !Link {
    const mod = try pipe.module_pool.getPtr(handle);
    for (mod.sockets) |maybe| {
        const sock = maybe orelse continue;
        if (sock.type.direction() != .input) continue;
        const conn = sock.connected_to_module orelse continue;
        const src = try pipe.module_pool.getPtr(conn.item);
        const src_sock = src.sockets[conn.socket_idx] orelse continue;
        return .{ .module = conn.item, .socket = src_sock.name };
    }
    return error.GraphSinkMissingInput;
}

/// Append a `downscale` capping the longest edge, returning the new tail.
fn appendDownscale(pipe: *pipeline.Pipeline, tail: Link, max_edge: u32) !Link {
    const downscale = try pipe.addModuleNoRecord("01", "downscale");
    try pipe.setModuleParam(downscale, "max_edge", i32, @intCast(max_edge));
    try pipe.connectModulesNoRecord(tail.module, tail.socket, downscale, "input");
    return .{ .module = downscale, .socket = "output" };
}
