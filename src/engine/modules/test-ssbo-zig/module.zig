//! Test module for a buffer connection between two Zig SPIR-V nodes.
//!
//! Node 1 reads the input texture and writes one f32 per channel to a
//! storage buffer. Node 2 reads the buffer and writes the output texture.

const api = @import("../api.zig");

pub const def: api.ModuleDef = .{
    .desc = .{
        .name = "test-ssbo-zig",
        .type = .compute,
        .params = &.{},
        .params_ui = &.{},
        .sockets = &.{
            .{ .name = "input", .access = .read, .resource = .rgba, .datatype = .f16 },
            .{ .name = "output", .access = .write, .resource = .rgba, .datatype = .f16 },
        },
    },
    .createNodes = createNodes,
};

pub fn createNodes(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    const output_sock = try api.getModSocket(pipe, mod, "output");
    const roi = output_sock.roi orelse return error.ModuleROIMissing;

    // Four f32 elements for each pixel.
    const buffer_extent: api.ROI = .{ .w = roi.w * roi.h * 4 + 2, .h = 1 };

    const scatter = try api.addNode(pipe, mod, @import("node.scatter.zon"));
    try api.setNodeSocketRoi(pipe, scatter, "tmp", buffer_extent);
    try api.setNodeRunSize(pipe, scatter, roi);

    const gather = try api.addNode(pipe, mod, @import("node.gather.zon"));
    try api.setNodeSocketRoi(pipe, gather, "tmp", buffer_extent);
    try api.setNodeRunSize(pipe, gather, roi);

    try api.inheritSocket(pipe, mod, "input", scatter, "input");
    try api.connectNodesByName(pipe, scatter, "tmp", gather, "tmp");
    try api.inheritSocket(pipe, mod, "output", gather, "output");
}
