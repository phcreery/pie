//! Recommended default pipelines, keyed by input file type.

const std = @import("std");
const api = @import("modules/api.zig");
const gpu = @import("gpu");
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
    try serdes.deserialize(pipe, std.Io.Reader.fixed(format.graph));

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
        // Insert as soon as the chain produces working rgb: every module after
        // that point is per-pixel, so a thumbnail only pays full resolution up
        // to the demosaic instead of running the whole tail and shrinking it.
        try insertDownscale(pipe, sink, max_edge);
        // the sink may now be fed by the downscale itself
        tail = try upstream(pipe, sink);
    }

    if (options.output_path != null) {
        // swap the current sink with the output module
        const display_module_handle = try pipe.module_pool.getPtr(sink);
        try pipe.removeModuleByNameNoRecord(display_module_handle.name, display_module_handle.id);
        sink = try pipe.addModuleNoRecord(options.output_module, "01");
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

/// Insert a `downscale` capping the longest edge at the end of the raw/CFA
/// domain: after the last producer that already emits working rgb
/// (`rgba16float`). Falls back to just upstream of the sink when the chain
/// never leaves the raw domain.
fn insertDownscale(pipe: *pipeline.Pipeline, sink: pipeline.ModuleHandle, max_edge: u32) !void {
    var producer = try upstream(pipe, sink);
    var consumer = sink;
    var consumer_socket = try inputConnectedTo(pipe, consumer, producer.module);

    var insert_after = producer;
    var insert_consumer = consumer;
    var insert_socket = consumer_socket;

    // walk upstream while the producer is already in working rgb; stop at the
    // first raw-domain producer, which is where the thumbnail should start
    while (try producerSocketFormat(pipe, producer) == .rgba16float) {
        insert_after = producer;
        insert_consumer = consumer;
        insert_socket = consumer_socket;

        const parent = upstream(pipe, producer.module) catch break;
        consumer_socket = try inputConnectedTo(pipe, producer.module, parent.module);
        consumer = producer.module;
        producer = parent;
    }

    // copy the identity out before `addModuleNoRecord` can move the pool
    const consumer_mod = try pipe.module_pool.getPtr(insert_consumer);
    const consumer_name = consumer_mod.name;
    const consumer_id = consumer_mod.id;
    try pipe.disconnectModuleByNameNoRecord(consumer_name, consumer_id, insert_socket);

    const downscale = try pipe.addModuleNoRecord("downscale", "01");
    try pipe.setModuleParam(downscale, "max_edge", i32, @intCast(max_edge));
    try pipe.connectModulesNoRecord(insert_after.module, insert_after.socket, downscale, "input");
    try pipe.connectModulesNoRecord(downscale, "output", insert_consumer, insert_socket);
}

fn producerSocketFormat(pipe: *pipeline.Pipeline, link: Link) !gpu.TextureFormat {
    const mod = try pipe.module_pool.getPtr(link.module);
    const sock = try mod.getSocketPtr(link.socket);
    return sock.format;
}

/// Name of `consumer`'s input socket that is connected to `producer`.
fn inputConnectedTo(
    pipe: *pipeline.Pipeline,
    consumer: pipeline.ModuleHandle,
    producer: pipeline.ModuleHandle,
) ![]const u8 {
    const mod = try pipe.module_pool.getPtr(consumer);
    for (mod.sockets) |maybe| {
        const sock = maybe orelse continue;
        if (sock.type.direction() != .input) continue;
        const conn = sock.connected_to_module orelse continue;
        if (conn.item.id == producer.id) return sock.name;
    }
    return error.GraphSinkMissingInput;
}

test "thumbnail graph downscales before the per-pixel tail" {
    const testing = std.testing;
    var pipe = try pipeline.Pipeline.init(testing.allocator, testing.io, null, .{});
    defer pipe.deinit();

    _ = try recommendFormat(&pipe, &formats[0], .{ .max_edge = 256 });

    const downscale = pipe.module_name_map.get("downscale:01") orelse
        return error.TestUnexpectedResult;
    const demosaic = pipe.module_name_map.get("demosaic:01") orelse
        return error.TestUnexpectedResult;
    const crop = pipe.module_name_map.get("crop:01") orelse
        return error.TestUnexpectedResult;

    // raw domain -> demosaic -> downscale -> crop -> ... -> sink
    try testing.expectEqual(demosaic.id, (try upstream(&pipe, downscale)).module.id);
    try testing.expectEqual(downscale.id, (try upstream(&pipe, crop)).module.id);
}
