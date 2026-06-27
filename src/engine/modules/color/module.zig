const api = @import("../api.zig");
const std = @import("std");
const temp_tint = @import("./temp_tint.zig");

pub var desc: api.ModuleDesc = .{
    .name = "color",
    .type = .compute,
    .params = init: {
        var p: [api.MAX_PARAMS_PER_MODULE]?api.ParamDesc = @splat(null);
        p[0] = .{ .name = "wb_temp", .len = 1, .typ = .f32 };
        p[1] = .{ .name = "wb_tint", .len = 1, .typ = .f32 };
        p[2] = .{ .name = "wb_coeff", .len = 3, .typ = .f32 };
        break :init p;
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
    .modifyROIOut = modifyROIOut,
    .createNodes = createNodes,
};

const default_wb_temp: f32 = 6500.0; // D65 daylight
const default_wb_tint: f32 = 0.0;
const default_wb_coeff: [3]f32 = .{ 1.0, 1.0, 1.0 }; // hardcoded from 1/(srgb_from_xyz*xyz_d65_from_cam*(1/wb_cam)) of DSC_6765.NEF

pub fn initParams(pipe: *api.Pipeline, mod: api.ModuleHandle) !void {
    try api.initParamNamed(pipe, mod, "wb_temp", default_wb_temp);
    try api.initParamNamed(pipe, mod, "wb_tint", default_wb_tint);

    // 1.90625, 1, 1.4921875    cam_mul
    // 0.8191, 1, 1.3340, 1.0   hardcoded from 1/(rec2020_from_xyz*xyz_d65_from_cam*(1/wb_cam)) of DSC_6765.NEF
    // 0.70393723, 1, 1.3611937 hardcoded from 1/(srgb_from_xyz*xyz_d65_from_cam*(1/wb_cam)) of DSC_6765.NEF
    // try api.initParamNamed(pipe, mod, "wb_coeff", [3]f32{ 0.70393723, 1, 1.3611937 });
    try api.initParamNamed(pipe, mod, "wb_coeff", default_wb_coeff);
}

pub fn modifyROIOut(pipe: *api.Pipeline, mod: api.ModuleHandle) !void {
    // Propagate ROI from input to output (normally done by pipeline when modifyROIOut is absent)
    const input_socket = try api.getModSocket(pipe, mod, "input");
    var output_socket = try api.getModSocket(pipe, mod, "output");
    output_socket.roi = input_socket.roi;

    // Temp/tint is now applied post-demosaic in color.wgsl as a relative
    // camera-space correction before camera->sRGB conversion.
    const wb_temp = try api.getParam(pipe, mod, "wb_temp", f32);
    const wb_tint = try api.getParam(pipe, mod, "wb_tint", f32);
    const wb_coeff = try api.getParam(pipe, mod, "wb_coeff", [3]f32);
    std.debug.print("color module: wb_temp={d:.0} wb_tint={d:.1}\n", .{ wb_temp, wb_tint });
    std.debug.print("color module: wb_coeff=({d:.4}, {d:.4}, {d:.4})\n", .{ wb_coeff[0], wb_coeff[1], wb_coeff[2] });

    // If we have xyz_d65_from_cam from the upstream module, just print the relative
    // correction that the shader will apply. We do not modify img_param.white_balance
    // here, because the raw-domain WB was already applied upstream.
    const m = try api.getModule(pipe, mod);
    if (m.img_param) |*img_param| {
        const neutral_wb = temp_tint.computeWhiteBalanceFromTempTint(default_wb_temp, default_wb_tint, img_param.xyz_d65_from_cam);
        const target_wb = temp_tint.computeWhiteBalanceFromTempTint(wb_temp, wb_tint, img_param.xyz_d65_from_cam);
        const rel_r = std.math.clamp(target_wb[0] / @max(neutral_wb[0], 1e-6), 1e-4, 64.0);
        const rel_g = std.math.clamp(target_wb[1] / @max(neutral_wb[1], 1e-6), 1e-4, 64.0);
        const rel_b = std.math.clamp(target_wb[2] / @max(neutral_wb[2], 1e-6), 1e-4, 64.0);
        std.debug.print("color module: wb_temp={d:.0} wb_tint={d:.1} rel_post_demosaic=({d:.4}, {d:.4}, {d:.4})\n", .{
            wb_temp,
            wb_tint,
            rel_r,
            rel_g,
            rel_b,
        });
    } else {
        std.debug.print("color module: no img_param propagated yet (sink_after_color path?)\n", .{});
    }
}

pub fn createNodes(pipe: *api.Pipeline, mod: api.ModuleHandle) !void {
    const mod_output_sock = try api.getModSocket(pipe, mod, "output");
    const node_color = try pipe.addNode(mod, .{
        .type = .compute,
        .shader = @embedFile("./color.wgsl"),
        .name = "color",
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
    try pipe.copyConnector(mod, "input", node_color, "input");
    try pipe.copyConnector(mod, "output", node_color, "output");
}
