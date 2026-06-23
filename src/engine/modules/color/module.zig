const api = @import("../api.zig");
const std = @import("std");

pub var desc: api.ModuleDesc = .{
    .name = "color",
    .type = .compute,
    .params = init: {
        var p: [api.MAX_PARAMS_PER_MODULE]?api.ParamDesc = @splat(null);
        p[0] = .{ .name = "wb_temp", .len = 1, .typ = .f32 };
        p[1] = .{ .name = "wb_tint", .len = 1, .typ = .f32 };
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

pub fn initParams(pipe: *api.Pipeline, mod: api.ModuleHandle) !void {
    try api.initParamNamed(pipe, mod, "wb_temp", default_wb_temp);
    try api.initParamNamed(pipe, mod, "wb_tint", default_wb_tint);
}

const Chromaticity = struct { x: f32, y: f32 };
const Uv = struct { u: f32, v: f32 };

/// CIE 1931 xy chromaticity from correlated color temperature.
/// Approximation is valid for about 1667K..25000K, so clamp into that range.
fn cctToXy(cct_in: f32) Chromaticity {
    const cct = std.math.clamp(cct_in, 1667.0, 25000.0);
    const cct3 = cct * cct * cct;
    const cct2 = cct * cct;
    const inv_cct3 = 1e9 / cct3;
    const inv_cct2 = 1e6 / cct2;
    const inv_cct = 1e3 / cct;

    const x: f32 = if (cct <= 4000.0)
        -0.2661239 * inv_cct3 - 0.2343589 * inv_cct2 + 0.8776956 * inv_cct + 0.179910
    else
        -3.0258469 * inv_cct3 + 2.1070379 * inv_cct2 + 0.2226347 * inv_cct + 0.240390;

    const y: f32 = if (cct <= 2222.0)
        -1.1063814 * x * x * x - 1.34811020 * x * x + 2.18555832 * x - 0.20219683
    else if (cct <= 4000.0)
        -0.9549476 * x * x * x - 1.37418593 * x * x + 2.09137015 * x - 0.16748867
    else
        3.0817580 * x * x * x - 5.87338670 * x * x + 3.75112997 * x - 0.37001483;

    return .{ .x = x, .y = y };
}

/// CIE 1976 UCS u'v' from CIE 1931 xy.
fn xyToUv(x: f32, y: f32) Uv {
    const denom = -2.0 * x + 12.0 * y + 3.0;
    return .{ .u = 4.0 * x / denom, .v = 9.0 * y / denom };
}

/// CIE 1931 xy from CIE 1976 UCS u'v' (inverse of xyToUv).
fn uvToXy(u: f32, v: f32) Chromaticity {
    const denom = 6.0 * u - 16.0 * v + 12.0;
    return .{ .x = 9.0 * u / denom, .y = 4.0 * v / denom };
}

fn sanitizeChromaticity(xy_in: Chromaticity) Chromaticity {
    if (!std.math.isFinite(xy_in.x) or !std.math.isFinite(xy_in.y)) {
        // D65 fallback.
        return .{ .x = 0.3127, .y = 0.3290 };
    }

    var x = xy_in.x;
    var y = xy_in.y;

    x = std.math.clamp(x, 1e-4, 0.9998);
    y = std.math.clamp(y, 1e-4, 0.9998);

    const sum = x + y;
    if (sum >= 0.9998) {
        const scale = 0.9998 / sum;
        x *= scale;
        y *= scale;
    }

    return .{ .x = x, .y = y };
}

fn locusNormalAtTemp(temp: f32) Uv {
    const cct = std.math.clamp(temp, 1667.0, 25000.0);
    const delta = @max(10.0, cct * 0.0025);
    const uv_lo = blk: {
        const xy = cctToXy(cct - delta);
        break :blk xyToUv(xy.x, xy.y);
    };
    const uv_hi = blk: {
        const xy = cctToXy(cct + delta);
        break :blk xyToUv(xy.x, xy.y);
    };

    const du = uv_hi.u - uv_lo.u;
    const dv = uv_hi.v - uv_lo.v;
    const len = @sqrt(du * du + dv * dv);
    if (len <= 1e-8) return .{ .u = 0.0, .v = 1.0 };

    // Positive tint moves along the normal with positive u'/v' components near daylight.
    // If the UI feels inverted, negate tint before calling this function.
    return .{ .u = -dv / len, .v = du / len };
}

/// Compute camera white-balance multipliers from CCT + tint.
/// temp moves along the daylight/Planckian locus,
/// tint moves approximately perpendicular to that locus in CIE 1976 u'v'.
/// With only a single camera matrix available we cannot do full DNG-style dual-
/// illuminant interpolation, but this is much closer than independent u'/v' shifts.
fn computeWhiteBalanceFromTempTint(temp: f32, tint: f32, xyz_from_cam: [3][3]f32) [4]f32 {
    // 1. Temperature chooses a chromaticity on the locus.
    const xy0 = cctToXy(temp);
    const uv0 = xyToUv(xy0.x, xy0.y);

    // 2. Tint offsets perpendicular to the local locus tangent.
    //    Scale chosen so ±100 is a moderate green/magenta adjustment.
    const tint_scale = 5e-5;
    const n = locusNormalAtTemp(temp);
    const uv = Uv{
        .u = uv0.u + tint_scale * tint * n.u,
        .v = uv0.v + tint_scale * tint * n.v,
    };

    // 3. Back to xy, keeping the chromaticity sane.
    const xy = sanitizeChromaticity(uvToXy(uv.u, uv.v));

    // 4. xy to XYZ (Y = 1.0).
    const X = xy.x / xy.y;
    const Y = 1.0;
    const Z = (1.0 - xy.x - xy.y) / xy.y;

    // 5. XYZ to camera RGB.
    const cam_from_xyz: [3][3]f32 = api.math.mat3.inv(f32, xyz_from_cam);

    var rgb: [3]f32 = undefined;
    for (0..3) |cam_ch| {
        rgb[cam_ch] = cam_from_xyz[cam_ch][0] * X +
            cam_from_xyz[cam_ch][1] * Y +
            cam_from_xyz[cam_ch][2] * Z;
        if (!std.math.isFinite(rgb[cam_ch]) or rgb[cam_ch] <= 1e-6) {
            rgb[cam_ch] = 1e-6;
        }
    }

    // 6. White balance gains are the inverse of the camera response to the
    //    chosen white point. Normalize so green gain = 1.0 and mirror to G2.
    const green = @max(rgb[1], 1e-6);
    return .{ green / rgb[0], 1.0, green / rgb[2], 1.0 };
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
    std.debug.print("color module: wb_temp={d:.0} wb_tint={d:.1}\n", .{ wb_temp, wb_tint });

    // If we have xyz_from_cam from the upstream module, just print the relative
    // correction that the shader will apply. We do not modify img_param.white_balance
    // here, because the raw-domain WB was already applied upstream.
    const m = try api.getModule(pipe, mod);
    if (m.img_param) |*img_param| {
        const neutral_wb = computeWhiteBalanceFromTempTint(default_wb_temp, default_wb_tint, img_param.xyz_from_cam);
        const target_wb = computeWhiteBalanceFromTempTint(wb_temp, wb_tint, img_param.xyz_from_cam);
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
