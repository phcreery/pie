const api = @import("../api.zig");

pub const desc: api.ModuleDesc = .{
    .name = "filmcurv",
    .type = .compute,
    .params = &.{
        .{ .name = "brightness", .len = 1, .typ = .f32 },
        .{ .name = "contrast", .len = 1, .typ = .f32 },
        .{ .name = "bias", .len = 1, .typ = .f32 },
        .{ .name = "colormode", .len = 1, .typ = .i32 },
    },
    .params_ui = &.{
        .{ .name = "brightness", .control = .{ .slider = .{ .min = 0, .max = 7, .step = 0.01 } } },
        .{ .name = "contrast", .control = .{ .slider = .{ .min = 0, .max = 4, .step = 0.01 } } },
        .{ .name = "bias", .control = .{ .slider = .{ .min = -0.05, .max = 0.2, .step = 0.01 } } },
        .{ .name = "colormode", .control = .{ .combo = .{ .items = &.{"AgX"} } } },
    },
    .sockets = &.{
        .{ .name = "input", .type = .read, .format = .rgba16float, .color_profile = .any },
        .{ .name = "output", .type = .write, .format = .rgba16float, .color_profile = .any },
    },
    .initParams = initParams,
    .createNodes = createNodes,
};

pub fn initParams(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    try api.initParamNamed(pipe, mod, "brightness", @as(f32, 2.22));
    try api.initParamNamed(pipe, mod, "contrast", @as(f32, 1.0));
    try api.initParamNamed(pipe, mod, "bias", @as(f32, 0.0));
    try api.initParamNamed(pipe, mod, "colormode", @as(i32, 0));
}

pub fn createNodes(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    const mod_output_sock = try api.getModSocket(pipe, mod, "output");
    const node_filmcurv = try api.addNode(pipe, mod, @import("node.filmcurv.zon"));
    try api.setNodeRunSize(pipe, node_filmcurv, mod_output_sock.roi.?);
    try api.inheritSocket(pipe, mod, "input", node_filmcurv, "input");
    try api.inheritSocket(pipe, mod, "output", node_filmcurv, "output");
}
