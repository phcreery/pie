const api = @import("../api.zig");

pub var desc: api.ModuleDesc = .{
    .name = "filmcurv",
    .type = .compute,
    .params = init: {
        var p: [api.MAX_PARAMS_PER_MODULE]?api.ParamDesc = @splat(null);
        p[0] = .{ .name = "brightness", .len = 1, .typ = .f32 };
        p[1] = .{ .name = "contrast", .len = 1, .typ = .f32 };
        p[2] = .{ .name = "bias", .len = 1, .typ = .f32 };
        p[3] = .{ .name = "colormode", .len = 1, .typ = .i32 }; // 4 = AgX-like mode from vkdt filmcurv
        break :init p;
    },
    .params_ui = init: {
        var ui: [api.MAX_PARAMS_PER_MODULE]?api.ParamUI = @splat(null);
        ui[0] = .{ .name = "brightness", .control = .{ .slider = .{ .min = -4, .max = 4, .step = 0.01 } } };
        ui[1] = .{ .name = "contrast", .control = .{ .slider = .{ .min = -4, .max = 4, .step = 0.01 } } };
        ui[2] = .{ .name = "bias", .control = .{ .slider = .{ .min = -4, .max = 4, .step = 0.01 } } };
        ui[3] = .{ .name = "colormode", .control = .{ .combo = .{ .items = &.{ "standard", "mode-1", "mode-2", "mode-3", "AgX" } } } };
        break :init ui;
    },
    .sockets = init: {
        var s: api.Sockets = @splat(null);
        s[0] = .{
            .name = "input",
            .type = .read,
            .format = .rgba16float,
            .roi = null,
        };
        s[1] = .{
            .name = "output",
            .type = .write,
            .format = .rgba16float,
            .roi = null,
        };
        break :init s;
    },
    .initParams = initParams,
    .createNodes = createNodes,
};

pub fn initParams(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    try api.initParamNamed(pipe, mod, "brightness", @as(f32, 2.22));
    try api.initParamNamed(pipe, mod, "contrast", @as(f32, 1.0));
    try api.initParamNamed(pipe, mod, "bias", @as(f32, 0.0));
    try api.initParamNamed(pipe, mod, "colormode", @as(i32, 4));
}

pub fn createNodes(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    const mod_output_sock = try api.getModSocket(pipe, mod, "output");
    const node_filmcurv = try api.addNodeDesc(pipe, mod, .{
        .type = .compute,
        .shader = .{ .wgsl = @embedFile("./filmcurv.wgsl") },
        // .shader = @embedFile("./main.comp"),
        // .temp_shader_language = .glsl,
        .name = "filmcurv",
        .run_size = mod_output_sock.roi.?,
        .sockets = init: {
            var s: api.Sockets = @splat(null);
            s[0] = .{
                .name = "input",
                .type = .read,
                .format = .rgba16float,
                .roi = null,
            };
            s[1] = .{
                .name = "output",
                .type = .write,
                .format = .rgba16float,
                .roi = mod_output_sock.roi,
            };
            break :init s;
        },
    });
    try api.copyConnector(pipe, mod, "input", node_filmcurv, "input");
    try api.copyConnector(pipe, mod, "output", node_filmcurv, "output");
}
