//! Convert a source's raw samples to the working float format.
//!
//! Both sockets are declared `.any`: the pipeline resolves the input format
//! from the connection (see `Pipeline.runModuleModifyOut`), `modifyOut` picks
//! the matching output format, and `createNodes` builds the node (shader +
//! concrete socket formats) for that pair. Adding a datatype is one branch in
//! each of `outputFormatFor`/`createNodes` plus one shader.
const std = @import("std");
const api = @import("../api.zig");
const gpu = @import("gpu");
const slog = std.log.scoped(.format);

pub const desc: api.ModuleDesc = .{
    .name = "format",
    .type = .compute,
    .params = &.{},
    .params_ui = &.{},
    .sockets = &.{
        .{
            .name = "input",
            .type = .read,
            .format = .any,
            .color_profile = .any,
        },
        .{
            .name = "output",
            .type = .write,
            .format = .any,
            .color_profile = .any,
        },
    },
    .modifyOut = modifyOut,
    .createNodes = createNodes,
};

/// The format this module emits for a given resolved input format.
fn outputFormatFor(input: gpu.TextureFormat) ?gpu.TextureFormat {
    return switch (input) {
        // 16-bit bayer mosaic -> single-channel float (raw pipeline)
        .rggb16uint => .rggb32float,
        // 16-bit RGBA -> normalized f16 (PNG and other integer sources)
        .rgba16uint => .rgba16float,
        else => null,
    };
}

pub fn modifyOut(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    const input = try api.getModSocket(pipe, mod, "input");
    const output = try api.getModSocket(pipe, mod, "output");

    output.format = outputFormatFor(input.format) orelse {
        slog.err("no conversion for input format '{s}'", .{@tagName(input.format)});
        return error.UnsupportedInputFormat;
    };
    output.roi = input.roi;
}

pub fn createNodes(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    const mod_input_sock = try api.getModSocket(pipe, mod, "input");
    const mod_output_sock = try api.getModSocket(pipe, mod, "output");

    // `api.addNode` takes a comptime descriptor and the shader is chosen from
    // the resolved input format, so each conversion is its own branch.
    const node = switch (mod_input_sock.format) {
        .rggb16uint => try api.addNode(pipe, mod, .{
            .type = .compute,
            .shader = .{ .wgsl = .{ .string = @embedFile("./u16_to_f32_rggb.wgsl") } },
            .name = "format",
            .sockets = &.{
                .{ .name = "input", .type = .read, .format = .rggb16uint },
                .{ .name = "output", .type = .write, .format = .rggb32float },
            },
        }),
        .rgba16uint => try api.addNode(pipe, mod, .{
            .type = .compute,
            .shader = .{ .wgsl = .{ .string = @embedFile("./u16_to_f16_rgba.wgsl") } },
            .name = "format",
            .sockets = &.{
                .{ .name = "input", .type = .read, .format = .rgba16uint },
                .{ .name = "output", .type = .write, .format = .rgba16float },
            },
        }),
        else => {
            slog.err("no conversion for input format '{s}'", .{@tagName(mod_input_sock.format)});
            return error.UnsupportedInputFormat;
        },
    };

    try api.setNodeRunSize(pipe, node, mod_output_sock.roi.?);
    try api.inheritSocket(pipe, mod, "input", node, "input");
    try api.inheritSocket(pipe, mod, "output", node, "output");
}
