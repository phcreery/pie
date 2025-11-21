const api = @import("../api.zig");
const std = @import("std");

pub const module: api.ModuleDesc = .{
    .name = "test-o-1234",
    .type = .sink,
    // .param_ui = "",
    // .param_uniform = "",
    // .input_sock = null,
    .input_socket = .{
        .name = "input",
        .type = .sink,
        .format = .rgba16float,
        .roi = null,
    },
    .init = null,
    .deinit = null,
    .readSource = null,
    .writeSink = writeSink,
    .createNodes = createNodes,
    .modifyROIOut = null,
};

const expected = [_]f16{ 2.0, 4.0, 6.0, 8.0 };

pub fn writeSink(
    pipe: *api.Pipeline,
    mod: *api.Module,
    mapped: *anyopaque,
) !void {
    _ = pipe;

    const roi = mod.getSocket("input").?.roi orelse unreachable;

    const download_buffer_ptr: [*]f16 = @ptrCast(@alignCast(mapped));
    const download_buffer_slice = download_buffer_ptr[0..(roi.size.w * roi.size.h * 4)];
    std.log.info("Sink buffer contents: {any}", .{download_buffer_slice});
    try std.testing.expectEqualSlices(f16, &expected, download_buffer_slice);
}

pub fn createNodes(pipe: *api.Pipeline, mod: *api.Module) !void {
    const same_as_mod_output_sock = mod.getSocket("input") orelse unreachable;
    const node_desc: api.NodeDesc = .{
        .type = .sink,
        .shader_code = "",
        .entry_point = "Sink",
        .run_size = null,
        .sockets = init: {
            var s: api.Sockets = @splat(null);
            s[0] = same_as_mod_output_sock;
            break :init s;
        },
    };
    const node = try pipe.addNodeDesc(mod, node_desc);
    try pipe.copyConnector(mod, "input", node, "input");
}
