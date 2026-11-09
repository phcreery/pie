const api = @import("../api.zig");
const std = @import("std");
const temp_tint = @import("./temp_tint.zig");
const slog = std.log.scoped(.color);
const math = @import("math");

const Vec3 = math.Vec3;
const Mat3 = math.Mat3;

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
/// What the shader gets when there is no camera data and no user override.
/// A neutral gain: the CAT16 source white is its reciprocal, i.e. D65.
const neutral_wb_gain: [3]f32 = .{ 1.0, 1.0, 1.0 };

pub fn initParams(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    // try api.initParam(pipe, mod, "wb_temp", default_wb_temp);
    // try api.initParam(pipe, mod, "wb_tint", default_wb_tint);

    // User override. All-zero means auto.
    // `commitParams` resolves the value from the source image camera matrix and
    // the raw white balance (`preWbGain`, see color.ipynb). It is a gain in
    // linear Rec.2020, green-normalized: raising a channel warms it.
    try api.initParam(pipe, mod, "wb_coeff", auto_wb_coeff);
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

    if (is_auto) {
        // OLD CODE - kept for backup. Delete after the test.
        // The shader used the gain vector as the CAT16 destination white.
        // const effective_wb_coeff = if (m.img_param) |img_param|
        //     api.math.color.preWbCoeff(img_param.xyz_d65_from_cam, img_param.white_balance)
        // else
        //     neutral_wb_coeff;
        // try api.initParam(pipe, mod, "wb_coeff", effective_wb_coeff);

        // New code.
        // `wb_coeff` holds a white-balance gain in linear Rec.2020: raising a
        // channel warms it. The shader takes its reciprocal as the CAT16
        // source white and adapts that to D65.
        const effective_wb_gain = if (m.img_param) |img_param|
            wbColorspaceConvert(img_param.xyz_d65_from_cam, img_param.white_balance)
        else
            neutral_wb_gain;
        try api.initParam(pipe, mod, "wb_coeff", effective_wb_gain);
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

inline fn recipOrOne(v: f32) f32 {
    return if (v > 1e-6) 1.0 / v else 1.0;
    // return v;
}

/// White-balance gain for the given raw white balance, in linear Rec.2020.
/// Green is 1.0. This is the reciprocal of `preWbWhite`: raising a channel
/// warms it in the `color` node, which converts it back into the CAT16 source
/// white.
pub fn wbColorspaceConvert(xyz_d65_from_cam: [3][3]f32, cam_mul: [4]f32) [3]f32 {
    const inv_gain = Vec3.new(
        recipOrOne(cam_mul[0]),
        recipOrOne(cam_mul[1]),
        recipOrOne(cam_mul[2]),
    );
    const xyz = Mat3.fromArray(xyz_d65_from_cam).mulVec(inv_gain);
    const rgb = math.color.matrices.rec2020_from_xyz_d65.mulVec(xyz);

    // Green is the reference channel. A non-positive green means the camera
    // matrix is not usable, so fall back to the D65 white.
    const green = rgb.y;
    if (!(green > 1e-6)) return .{ 1.0, 1.0, 1.0 };

    const white = Vec3.div(rgb, Vec3.all(green));

    const gain = Vec3.div(Vec3.one, white);
    return .{ gain.x, gain.y, gain.z };
}

test "rec2020 preWbWhite matches the color.ipynb reference" {
    const testing = @import("std").testing;
    // DSC_6765.NEF: as-shot camera white balance and XYZ<-camera from LibRaw.
    const cam_mul = [4]f32{ 1.90625, 1.0, 1.4921875, 1.0 };
    const xyz_d65_from_cam = [3][3]f32{
        .{ 1.5699793, 0.14481506, 0.10475578 },
        .{ 0.6360732, 0.8477491, -0.221411 },
        .{ 0.12701747, -0.2259345, 1.4544346 },
    };

    // The param is the gain (reciprocal of the white), green-normalized: the
    // notebook's Rec.2020 "pre-WB" values. Raising a channel warms the image.
    const gain = wbColorspaceConvert(xyz_d65_from_cam, cam_mul);
    try testing.expectApproxEqAbs(@as(f32, 0.8191874), gain[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1.0), gain[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.3340929), gain[2], 1e-5);
}
