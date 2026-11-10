const api = @import("../api.zig");
const std = @import("std");
const temp_tint = @import("./temp_tint.zig");
const slog = std.log.scoped(.color);
const math = @import("math");

const Vec3 = math.Vec3;
const Vec4 = math.Vec4;
const Mat3 = math.Mat3;
const rec2020_from_xyz_d65 = math.color.matrices.rec2020_from_xyz_d65;

pub const def: api.ModuleDef = .{
    .desc = @import("module.zon"),
    .initParams = initParams,
    .modifyOut = modifyOut,
    .commitParams = commitParams,
    .createNodes = createNodes,
};

// const default_wb_temp: f32 = 6500.0; // D65 daylight
// const default_wb_tint: f32 = 0.0;
/// `wb_coeff` sentinel: all-zero means "derive from the camera"
const auto_wb_coeff: [3]f32 = .{ 0.0, 0.0, 0.0 };

pub fn initParams(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    // try api.initParam(pipe, mod, "wb_temp", default_wb_temp);
    // try api.initParam(pipe, mod, "wb_tint", default_wb_tint);
    try api.initParam(pipe, mod, "wb_coeff", auto_wb_coeff);
}

pub fn modifyOut(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    const input_socket = try api.getModSocket(pipe, mod, "input");
    var output_socket = try api.getModSocket(pipe, mod, "output");
    output_socket.roi = input_socket.roi;
}

pub fn commitParams(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    const m = try api.getModule(pipe, mod);

    const wb_coeff = try api.getParam(pipe, mod, "wb_coeff", [3]f32);
    const is_auto = std.meta.eql(wb_coeff, auto_wb_coeff);

    if (is_auto) {
        var effective_wb_gain = Vec3.one;
        if (m.img_param) |img_param| {
            effective_wb_gain = wbColorspaceConvert(img_param.xyz_d65_from_cam, img_param.white_balance.swizzle("xyz"));
        }
        try api.initParam(pipe, mod, "wb_coeff", effective_wb_gain.toArray());
    }
}

pub fn createNodes(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    const mod_output_sock = try api.getModSocket(pipe, mod, "output");
    const node_color = try api.addNode(pipe, mod, @import("node.color.zon"));
    try api.setNodeRunSize(pipe, node_color, mod_output_sock.roi.?);
    try api.inheritSocket(pipe, mod, "input", node_color, "input");
    try api.inheritSocket(pipe, mod, "output", node_color, "output");
}

// ---------------------------------------------------------------------------
// White balance
// ---------------------------------------------------------------------------

pub fn wbColorspaceConvert(xyz_d65_from_cam: Mat3, wb_coeffs_cam: Vec3) Vec3 {
    // white = 1/wb_coeffs
    const white_cam = Vec3.one.div(wb_coeffs_cam);
    const white_rec2020 = rec2020_from_xyz_d65.mulVec(xyz_d65_from_cam.mulVec(white_cam));

    // fall back to the D65 white if the green channel is non-positive.
    const green = white_rec2020.y;
    if (!(green > 1e-6)) return Vec3.one;

    // normalize by the green channel
    const white = Vec3.div(white_rec2020, Vec3.all(green));

    const wb_coeffs_rec2020 = Vec3.div(Vec3.one, white);
    return wb_coeffs_rec2020;
}

test "rec2020 wbColorspaceConvert matches the color.ipynb reference" {
    const testing = @import("std").testing;
    // DSC_6765.NEF: as-shot camera white balance and XYZ<-camera from LibRaw.
    const cam_mul = Vec3.new(1.90625, 1.0, 1.4921875);
    const xyz_d65_from_cam = Mat3.fromArray(.{
        .{ 1.5699793, 0.14481506, 0.10475578 },
        .{ 0.6360732, 0.8477491, -0.221411 },
        .{ 0.12701747, -0.2259345, 1.4544346 },
    });

    // The param is the gain (reciprocal of the white), green-normalized: the
    // notebook's Rec.2020 "pre-WB" values. Raising a channel warms the image.
    const gain = wbColorspaceConvert(xyz_d65_from_cam, cam_mul);
    try testing.expectApproxEqAbs(@as(f32, 0.8191874), gain[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1.0), gain[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.3340929), gain[2], 1e-5);
}
