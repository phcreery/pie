//! Recommended default pipelines, keyed by input file type.
//!
//! This is the engine's answer to "how do I turn this file into an image": the
//! graph the editor opens and the lighter one the thumbnail decoder builds.
//! Both dispatch on the file extension through `kindForPath`, so supporting a
//! new format is one `FileKind` variant plus one branch here — the app no
//! longer keeps its own copy of the default graph.

const std = @import("std");
const pipeline = @import("pipeline.zig");

/// Input module families the engine knows how to decode.
pub const FileKind = enum {
    raw,
    png,
    unsupported,
};

const raw_extensions = [_][]const u8{
    "nef", "cr2", "cr3", "arw", "dng", "raf", "rw2", "orf", "pef", "srw", "nrw", "raw",
};

/// Which decoder handles `path`, judged from its extension alone.
pub fn kindForPath(path: []const u8) FileKind {
    const ext = std.fs.path.extension(path);
    if (ext.len < 2) return .unsupported;
    const bare = ext[1..]; // skip the dot
    for (raw_extensions) |candidate| {
        if (std.ascii.eqlIgnoreCase(bare, candidate)) return .raw;
    }
    if (std.ascii.eqlIgnoreCase(bare, "png")) return .png;
    return .unsupported;
}

pub const Options = struct {
    /// When set, a `downscale` module caps the longest edge of the output. The
    /// editor passes null (full resolution); the thumbnail decoder passes the
    /// catalog's thumbnail size.
    max_edge: ?u32 = null,
    /// When set, the graph ends in an `o-png` sink writing to this path instead
    /// of an `o-display` sink. The thumbnail decoder uses this to render into
    /// its on-disk cache.
    output_path: ?[]const u8 = null,
};

/// The endpoints of a recommended graph. `sink` is `o-display` unless
/// `Options.output_path` asked for `o-png`; callers that render repeatedly can
/// re-point the sink's `filename` param without rebuilding the graph.
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
    const graph = try recommendKind(pipe, kindForPath(path), options);
    try pipe.setModuleParam(graph.source, "filename", []const u8, path);
    return graph;
}

/// Build the recommended pipeline for a decoder family. The source's
/// `filename` param is left for the caller to set (e.g. to decode many files
/// through one cached pipeline).
pub fn recommendKind(
    pipe: *pipeline.Pipeline,
    kind: FileKind,
    options: Options,
) !Graph {
    return switch (kind) {
        .raw => recommendRaw(pipe, options),
        .png => recommendPng(pipe, options),
        .unsupported => error.UnsupportedFileType,
    };
}

fn recommendRaw(pipe: *pipeline.Pipeline, options: Options) !Graph {
    const source = try pipe.addModule("01", "i-raw");
    const format = try pipe.addModule("01", "format");
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

    try pipe.connectModules(source, "output", format, "input");
    try pipe.connectModules(format, "output", denoise, "input");
    try pipe.connectModules(denoise, "output", demosaic, "input");
    try pipe.connectModules(demosaic, "output", crop, "input");
    try pipe.connectModules(crop, "output", color, "input");
    try pipe.connectModules(color, "output", filmcurv, "input");

    const sink = try finish(pipe, filmcurv, options);
    return .{ .source = source, .sink = sink };
}
fn recommendPng(pipe: *pipeline.Pipeline, options: Options) !Graph {
    const source = try pipe.addModule("01", "i-png");
    const convert = try pipe.addModule("01", "format");
    try pipe.connectModules(source, "output", convert, "input");
    const sink = try finish(pipe, convert, options);
    return .{ .source = source, .sink = sink };
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
        const sink = try pipe.addModule("01", "o-png");
        try pipe.connectModules(tail, "output", sink, "input");
        try pipe.setModuleParam(sink, "filename", []const u8, path);
        return sink;
    }

    const display = try pipe.addModule("01", "o-display");
    try pipe.connectModules(tail, "output", display, "input");
    return display;
}
