const api = @import("../api.zig");

pub const module: api.ModuleDesc = .{
    .name = "test-i-1234",
    .type = .source,
    // .param_ui = "",
    // .param_uniform = "",
    .output_socket = .{
        .name = "output",
        .type = .source,
        .format = .rgba16float,
        .roi = null,
    },
    .init = null,
    .deinit = null,
    .readSource = readSource,
    .writeSink = null,
    .createNodes = createNodes,
    .modifyROIOut = modifyROIOut,
};

const source = [_]f16{ 1.0, 2.0, 3.0, 4.0 };
const roi: api.ROI = .{
    .size = .{
        .w = 1,
        .h = 1,
    },
    .origin = .{
        .x = 0,
        .y = 0,
    },
};

pub fn modifyROIOut(pipe: *api.Pipeline, mod: *api.Module) !void {
    _ = pipe;
    mod.desc.output_socket.?.roi = roi;
}

pub fn readSource(
    pipe: *api.Pipeline,
    mod: *api.Module,
    mapped: *anyopaque,
) !void {
    _ = pipe;
    _ = mod;

    const upload_buffer_ptr: [*]f16 = @ptrCast(@alignCast(mapped));
    // const upload_buffer_slice = upload_buffer_ptr[0..(roi.size.w * roi.size.h * 4)];
    @memcpy(upload_buffer_ptr, &source);
}

pub fn createNodes(pipe: *api.Pipeline, mod: *api.Module) !void {
    const same_as_mod_output_sock = mod.getSocket("output") orelse unreachable;
    const node_desc: api.NodeDesc = .{
        .type = .source,
        .shader_code = "",
        .entry_point = "Source",
        .run_size = null,
        .sockets = init: {
            var s: api.Sockets = @splat(null);
            s[0] = same_as_mod_output_sock;
            break :init s;
        },
    };
    const node = try api.addNodeDesc(pipe, mod, node_desc);
    try api.copyConnector(pipe, mod, "output", node, "output");
}
