const api = @import("../api.zig");

pub const desc: api.ModuleDesc = .{
    .name = "test-i-1234",
    .type = .source,
    .sockets = init: {
        var s: api.Sockets = @splat(null);
        s[0] = .{
            .name = "output",
            .type = .source,
            .format = .rgba16float,
            .roi = null,
        };
        break :init s;
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
    .w = 1,
    .h = 1,
};

pub fn modifyROIOut(pipe: *api.Pipeline, mod: api.ModuleHandle) !void {
    var socket = try api.getModSocket(pipe, mod, "output");
    socket.roi = roi;

    var m = try api.getModule(pipe, mod);
    m.img_param = .{
        .white = .{ 1.0, 2.0, 3.0, 4.0 },
        .black = .{ 1.0, 2.0, 3.0, 4.0 },
        .white_balance = .{ 1.0, 1.0, 1.0, 1.0 },
        .cam_to_rec2020 = .{
            .{ 1.0, 0.0, 0.0 },
            .{ 0.0, 1.0, 0.0 },
            .{ 0.0, 0.0, 1.0 },
        },
    };
}

pub fn readSource(pipe: *api.Pipeline, mod: api.ModuleHandle, mapped: *anyopaque) !void {
    _ = pipe;
    _ = mod;

    const upload_buffer_ptr: [*]f16 = @ptrCast(@alignCast(mapped));
    // const upload_buffer_slice = upload_buffer_ptr[0..(roi.w * roi.h * 4)];
    @memcpy(upload_buffer_ptr, &source);
}

pub fn createNodes(pipe: *api.Pipeline, mod: api.ModuleHandle) !void {
    const same_as_mod_output_sock = try api.getModSocket(pipe, mod, "output");
    const node = try api.addNode(pipe, mod, .{
        .type = .source,
        .name = "Source",
        .run_size = null,
        .sockets = init: {
            var s: api.Sockets = @splat(null);
            s[0] = same_as_mod_output_sock.*;
            break :init s;
        },
    });
    try api.copyConnector(pipe, mod, "output", node, "output");
}
