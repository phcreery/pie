//! Recommended default pipelines, keyed by input file type.
//!
//! The decoders are a table: for each `i-*` module, the extensions it claims
//! and the chain that turns its output into a display-referred image. Both the
//! graph the editor opens and the lighter one the thumbnail cache builds
//! dispatch through `formatForPath`, so no caller keeps its own list of what
//! the engine can decode and a new decoder is one table row.

const std = @import("std");
const pipeline = @import("pipeline.zig");

/// One decodable input family.
pub const Format = struct {
    /// The `i-*` module that reads the file; also identifies the family.
    source_module: []const u8,
    /// File extensions this family claims, without the leading dot.
    extensions: []const []const u8,
    /// Add whatever turns the source's output into something a sink accepts,
    /// returning the last module of that chain.
    connect: *const fn (pipe: *pipeline.Pipeline, source: pipeline.ModuleHandle) anyerror!pipeline.ModuleHandle,
};

/// Every input family the engine decodes.
const formats = [_]Format{
    .{
        .source_module = "i-raw",
        .extensions = &.{
            "nef", "cr2", "cr3", "arw", "dng", "raf", "rw2", "orf", "pef", "srw", "nrw", "raw",
        },
        .connect = connectRaw,
    },
    .{
        .source_module = "i-png",
        .extensions = &.{"png"},
        .connect = connectPng,
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
    /// an `o-display` sink. The thumbnail decoder uses this to render into its
    /// on-disk cache.
    output_path: ?[]const u8 = null,
    /// Sink module that writes `output_path`. Any `o-*` module with an
    /// rgba16float input and a `filename` param works (`o-png`, `o-qoi`, ...).
    output_module: []const u8 = "o-png",
};

/// The endpoints of a recommended graph. `sink` is `o-display` unless
/// `Options.output_path` asked for a file sink; callers that render repeatedly
/// can re-point the sink's `filename` param without rebuilding the graph.
pub const Graph = struct {
    source: pipeline.ModuleHandle,
    sink: pipeline.ModuleHandle,
};

/// Build the recommended pipeline for `path` and point its source at the file.
pub fn recommend(
    pipe: *pipeline.Pipeline,
    path: []const u8,
    options: Options,
) !Graph {
    const format = formatForPath(path) orelse return error.UnsupportedFileType;
    const graph = try recommendFormat(pipe, format, options);
    try pipe.setModuleParam(graph.source, "filename", []const u8, path);
    return graph;
}

/// Build the recommended pipeline for a decoder family. The source's
/// `filename` param is left for the caller to set (e.g. to decode many files
/// through one cached pipeline).
pub fn recommendFormat(
    pipe: *pipeline.Pipeline,
    format: *const Format,
    options: Options,
) !Graph {
    const source = try pipe.addModule("01", format.source_module);
    const last = try format.connect(pipe, source);
    const sink = try finish(pipe, last, options);
    return .{ .source = source, .sink = sink };
}

/// `i-raw -> format -> denoise -> demosaic -> crop -> color -> filmcurv`
fn connectRaw(pipe: *pipeline.Pipeline, source: pipeline.ModuleHandle) !pipeline.ModuleHandle {
    const convert = try pipe.addModule("01", "format");
    const denoise = try pipe.addModule("01", "denoise");
    const demosaic = try pipe.addModule("01", "demosaic");
    const crop = try pipe.addModule("01", "crop");
    const color = try pipe.addModule("01", "color");
    const filmcurv = try pipe.addModule("01", "filmcurv");

    try pipe.setModuleParam(source, "wb_mode", i32, 0);
    try pipe.setModuleParam(color, "wb_tint", f32, 0.0);
    // from 1/(srgb_from_xyz*xyz_d65_from_cam*(1/wb_cam)) of DSC_6765.NEF
    try pipe.setModuleParam(color, "wb_coeff", [3]f32, .{ 0.70393723, 1, 1.3611937 });
    try pipe.setModuleParam(filmcurv, "colormode", i32, 1);
    try pipe.setModuleParam(filmcurv, "brightness", f32, 3.8);
    try pipe.setModuleParam(filmcurv, "contrast", f32, 1.3);
    try pipe.setModuleParam(filmcurv, "bias", f32, 0.0);

    try pipe.connectModules(source, "output", convert, "input");
    try pipe.connectModules(convert, "output", denoise, "input");
    try pipe.connectModules(denoise, "output", demosaic, "input");
    try pipe.connectModules(demosaic, "output", crop, "input");
    try pipe.connectModules(crop, "output", color, "input");
    try pipe.connectModules(color, "output", filmcurv, "input");
    return filmcurv;
}

/// `i-png -> format`
fn connectPng(pipe: *pipeline.Pipeline, source: pipeline.ModuleHandle) !pipeline.ModuleHandle {
    const convert = try pipe.addModule("01", "format");
    try pipe.connectModules(source, "output", convert, "input");
    return convert;
}

/// Connect `last` to an optional downscale and then the output sink, returning
/// the sink's module handle.
fn finish(
    pipe: *pipeline.Pipeline,
    last: pipeline.ModuleHandle,
    options: Options,
) !pipeline.ModuleHandle {
    var tail = last;
    if (options.max_edge) |max_edge| {
        const downscale = try pipe.addModule("01", "downscale");
        try pipe.setModuleParam(downscale, "max_edge", i32, @intCast(max_edge));
        try pipe.connectModules(tail, "output", downscale, "input");
        tail = downscale;
    }

    if (options.output_path) |path| {
        const sink = try pipe.addModule("01", options.output_module);
        try pipe.connectModules(tail, "output", sink, "input");
        try pipe.setModuleParam(sink, "filename", []const u8, path);
        return sink;
    }

    const display = try pipe.addModule("01", "o-display");
    try pipe.connectModules(tail, "output", display, "input");
    return display;
}
