const api = @import("../api.zig");
const std = @import("std");
const temp_tint = @import("./temp_tint.zig");
const slog = std.log.scoped(.color);

pub const def: api.ModuleDef = .{
    .desc = @import("module.zon"),
    .initParams = initParams,
    .modifyOut = modifyOut,
    .commitParams = commitParams,
    .createNodes = createNodes,
};

const default_wb_temp: f32 = 6500.0; // D65 daylight
const default_wb_tint: f32 = 0.0;
/// `wb_coeff` sentinel: all-zero means "derive from the camera"
const auto_wb_coeff: [3]f32 = .{ 0.0, 0.0, 0.0 };
/// What the shader gets when there is no camera data and no user override.
const neutral_wb_coeff: [3]f32 = .{ 1.0, 1.0, 1.0 };

pub fn initParams(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    try api.initParam(pipe, mod, "wb_temp", default_wb_temp);
    try api.initParam(pipe, mod, "wb_tint", default_wb_tint);

    // User override; all-zero = auto. `commitParams` resolves it against the
    // source image's camera matrix and raw white balance
    // (`api.math.color.srgbPreWbCoeff`, see color.ipynb).
    try api.initParam(pipe, mod, "wb_coeff", auto_wb_coeff);
    try api.initParam(pipe, mod, "commited_wb_coeff", neutral_wb_coeff);
}

pub fn modifyOut(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    // Propagate ROI from input to output (normally done by pipeline when modifyOut is absent)
    const input_socket = try api.getModSocket(pipe, mod, "input");
    var output_socket = try api.getModSocket(pipe, mod, "output");
    output_socket.roi = input_socket.roi;
}

pub fn commitParams(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    const m = try api.getModule(pipe, mod);

    const wb_coeff = try api.getParam(pipe, mod, "wb_coeff", [3]f32);
    const is_auto = std.meta.eql(wb_coeff, auto_wb_coeff);

    const effective_wb_coeff: [3]f32 = if (!is_auto)
        wb_coeff
    else if (m.img_param) |img_param|
        api.math.color.srgbPreWbCoeff(img_param.xyz_d65_from_cam, img_param.white_balance)
    else
        neutral_wb_coeff;

    try api.initParam(pipe, mod, "commited_wb_coeff", effective_wb_coeff);

    // Temp/tint is now applied post-demosaic in color.wgsl as a relative
    // camera-space correction before camera->sRGB conversion.
    // const wb_temp = try api.getParam(pipe, mod, "wb_temp", f32);
    // const wb_tint = try api.getParam(pipe, mod, "wb_tint", f32);
    // const wb_coeff = try api.getParam(pipe, mod, "wb_coeff", [3]f32);
    // std.debug.print("color module: wb_temp={d:.0} wb_tint={d:.1}\n", .{ wb_temp, wb_tint });
    // std.debug.print("color module: wb_coeff=({d:.4}, {d:.4}, {d:.4})\n", .{ wb_coeff[0], wb_coeff[1], wb_coeff[2] });

    // If we have xyz_d65_from_cam from the upstream module, just print the relative
    // correction that the shader will apply. We do not modify img_param.white_balance
    // here, because the raw-domain WB was already applied upstream.
    // const m = try api.getModule(pipe, mod);
    // if (m.img_param) |*img_param| {
    //     const neutral_wb = temp_tint.computeWhiteBalanceFromTempTint(default_wb_temp, default_wb_tint, img_param.xyz_d65_from_cam);
    //     const target_wb = temp_tint.computeWhiteBalanceFromTempTint(wb_temp, wb_tint, img_param.xyz_d65_from_cam);
    //     const rel_r = std.math.clamp(target_wb[0] / @max(neutral_wb[0], 1e-6), 1e-4, 64.0);
    //     const rel_g = std.math.clamp(target_wb[1] / @max(neutral_wb[1], 1e-6), 1e-4, 64.0);
    //     const rel_b = std.math.clamp(target_wb[2] / @max(neutral_wb[2], 1e-6), 1e-4, 64.0);
    //     std.debug.print("color module: wb_temp={d:.0} wb_tint={d:.1} rel_post_demosaic=({d:.4}, {d:.4}, {d:.4})\n", .{
    //         wb_temp,
    //         wb_tint,
    //         rel_r,
    //         rel_g,
    //         rel_b,
    //     });
    // } else {
    //     std.debug.print("color module: no img_param propagated yet (sink_after_color path?)\n", .{});
    // }
}

pub fn createNodes(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    const mod_output_sock = try api.getModSocket(pipe, mod, "output");
    const node_color = try api.addNode(pipe, mod, .{
        .type = .compute,
        .shader = .{ .wgsl = .{ .string = @embedFile("./color.wgsl") } },
        .name = "color",
        .sockets = &.{
            .{
                .name = "input",
                .type = .read,
                .format = .rgba16float,
            },
            .{
                .name = "output",
                .type = .write,
                .format = .rgba16float,
            },
        },
    });
    try api.setNodeRunSize(pipe, node_color, mod_output_sock.roi.?);
    try api.inheritSocket(pipe, mod, "input", node_color, "input");
    try api.inheritSocket(pipe, mod, "output", node_color, "output");
}
