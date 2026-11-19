//! Convert raw source samples to the working float formats.
//!
//! Both sockets use `.any` resource and datatype. The pipeline resolves the
//! input from the connection (see `Pipeline.runModuleModifyOut`). `modifyOut`
//! selects the output format. `createNodes` builds one node for the resolved
//! pair. To add a datatype, add one branch in `modifyOut` and `createNodes`,
//! and add one shader.
const std = @import("std");
const api = @import("../api.zig");
const slog = std.log.scoped(.format);

fn isRggbU16(sock: *const api.Socket) bool {
    return sock.resource == .rggb and sock.datatype == .u16;
}

fn isRgbaU16(sock: *const api.Socket) bool {
    return sock.resource == .rgba and sock.datatype == .u16;
}

pub const def: api.ModuleDef = .{
    .desc = .{
        .name = "format",
        .type = .compute,
        .params = &.{},
        .params_ui = &.{},
        .sockets = &.{
            .{
                .name = "input",
                .access = .read,
                .resource = .any,
                .datatype = .any,
                .color_profile = .any,
            },
            .{
                .name = "output",
                .access = .write,
                .resource = .any,
                .datatype = .any,
                .color_profile = .any,
            },
        },
    },
    .modifyOut = modifyOut,
    .createNodes = createNodes,
};

pub fn modifyOut(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    const input = try api.getModSocket(pipe, mod, "input");
    const output = try api.getModSocket(pipe, mod, "output");

    if (isRggbU16(input)) {
        output.resource = .rggb;
        output.datatype = .f32;
    } else if (isRgbaU16(input)) {
        output.resource = .rgba;
        output.datatype = .f16;
    } else {
        slog.err("no conversion for input format '{s}/{s}'", .{
            @tagName(input.resource),
            @tagName(input.datatype),
        });
        return error.UnsupportedInputFormat;
    }
    output.roi = input.roi;
}

pub fn createNodes(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    const mod_input_sock = try api.getModSocket(pipe, mod, "input");
    const mod_output_sock = try api.getModSocket(pipe, mod, "output");

    // `api.addNode` takes a comptime descriptor. The shader depends on the
    // resolved input format, so each conversion is a separate branch.
    const node = if (isRggbU16(mod_input_sock))
        try api.addNode(pipe, mod, .{
            .type = .compute,
            .shader = .{ .wgsl = .{ .string = @embedFile("./u16_to_f32_rggb.wgsl") } },
            .name = "format",
            .sockets = &.{
                .{ .name = "input", .access = .read, .resource = .rggb, .datatype = .u16 },
                .{ .name = "output", .access = .write, .resource = .rggb, .datatype = .f32 },
            },
        })
    else if (isRgbaU16(mod_input_sock))
        try api.addNode(pipe, mod, .{
            .type = .compute,
            .shader = .{ .wgsl = .{ .string = @embedFile("./u16_to_f16_rgba.wgsl") } },
            .name = "format",
            .sockets = &.{
                .{ .name = "input", .access = .read, .resource = .rgba, .datatype = .u16 },
                .{ .name = "output", .access = .write, .resource = .rgba, .datatype = .f16 },
            },
        })
    else {
        slog.err("no conversion for input format '{s}/{s}'", .{
            @tagName(mod_input_sock.resource),
            @tagName(mod_input_sock.datatype),
        });
        return error.UnsupportedInputFormat;
    };

    try api.setNodeRunSize(pipe, node, mod_output_sock.roi.?);
    try api.inheritSocket(pipe, mod, "input", node, "input");
    try api.inheritSocket(pipe, mod, "output", node, "output");
}
