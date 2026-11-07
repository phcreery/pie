//! Reusable f32 color math: sRGB transfer function, HSV round-trip, and the
//! Weibull "film curve" (plain and AGX-flavoured).
//!
//! Shared by shaders (`@import("shader").math.color`) and CPU-side module code.

const math = @import("root.zig");
const mat3 = @import("mat3.zig");
pub const matrices = @import("matrices.zig"); // color matrices, exported as `math.matrices`
const vec3 = @import("vec3.zig");

pub const Vec3f32 = mat3.Vec3f32;
pub const Mat3f32 = mat3.Mat3f32;

// ---------------------------------------------------------------------------
// sRGB transfer function (IEC 61966-2-1)
// ---------------------------------------------------------------------------

/// Linear -> sRGB encoded.
pub inline fn linearToSrgb(c: f32) f32 {
    if (c <= 0.0031308) return c * 12.92;
    return 1.055 * math.powf(c, 1.0 / 2.4) - 0.055;
}

pub inline fn linearToSrgbVec3(v: Vec3f32) Vec3f32 {
    return .{ linearToSrgb(v[0]), linearToSrgb(v[1]), linearToSrgb(v[2]) };
}

// ---------------------------------------------------------------------------
// White balance
// ---------------------------------------------------------------------------

/// Pre-white-balance multipliers in `rec2020_from_xyz`: the gains the raw-domain
/// white balance leaves behind, expressed in the space the consumer decodes to
/// (`color` now decodes to linear Rec.2020, see `node.color.zig`).
///
/// This is vkdt's `1 / (rec2020_from_xyz * xyz_d65_from_cam * (1 / cam_mul))`,
/// normalized so green is exactly 1.0:
///
///     xyz   = xyz_d65_from_cam * (1 / cam_mul)  // camera gains, camera -> XYZ
///     rgb   = rec2020_from_xyz * xyz              // ... in the working space
///     coeff = 1 / (rgb / rgb.g)
///
/// `cam_mul` is the as-shot (or daylight) camera white balance, `xyz_d65_from_cam`
/// the camera -> XYZ (D65) matrix.
pub fn preWbCoeff(xyz_d65_from_cam: [3][3]f32, cam_mul: [4]f32) [3]f32 {
    const inv_gain = Vec3f32{
        recipOrOne(cam_mul[0]),
        recipOrOne(cam_mul[1]),
        recipOrOne(cam_mul[2]),
    };
    const xyz = Mat3f32.fromArray(xyz_d65_from_cam).mulVec(inv_gain);
    const rgb = matrices.rec2020_from_xyz.mulVec(xyz);

    // Green is the reference channel; a non-positive green means the camera
    // matrix is not usable, so fall back to neutral.
    const green = rgb[1];
    if (!(green > 1e-6)) return .{ 1.0, 1.0, 1.0 };

    const coeff = vec3.recip(rgb / vec3.splat(green));
    return .{ coeff[0], coeff[1], coeff[2] };
}

inline fn recipOrOne(v: f32) f32 {
    return if (v > 1e-6) 1.0 / v else 1.0;
}

test "rec2020 preWbCoeff matches the color.ipynb reference" {
    const testing = @import("std").testing;
    // DSC_6765.NEF: as-shot camera white balance and XYZ<-camera from LibRaw.
    const cam_mul = [4]f32{ 1.90625, 1.0, 1.4921875, 1.0 };
    const xyz_d65_from_cam = [3][3]f32{
        .{ 1.5699793, 0.14481506, 0.10475578 },
        .{ 0.6360732, 0.8477491, -0.221411 },
        .{ 0.12701747, -0.2259345, 1.4544346 },
    };

    const coeff = preWbCoeff(xyz_d65_from_cam, cam_mul);
    try testing.expectApproxEqAbs(@as(f32, 0.8191874), coeff[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), coeff[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.3340929), coeff[2], 1e-6);

    // A singular camera matrix must not produce NaN/inf multipliers.
    const neutral = preWbCoeff(
        [3][3]f32{ .{ 0.0, 0.0, 0.0 }, .{ 0.0, 0.0, 0.0 }, .{ 0.0, 0.0, 0.0 } },
        .{ 0.0, 0.0, 0.0, 0.0 },
    );
    try testing.expectEqual([3]f32{ 1.0, 1.0, 1.0 }, neutral);
}

// ---------------------------------------------------------------------------
// HSV
// ---------------------------------------------------------------------------

/// Hue interpolation the short way around the wheel. Hue is in turns [0, 1).
pub inline fn lerpChromaticityAngle(h1: f32, h2: f32, t: f32) f32 {
    var h2m = h2;
    const delta = h2 - h1;
    if (delta > 0.5) {
        h2m = h2 - 1.0;
    } else if (delta < -0.5) {
        h2m = h2 + 1.0;
    }
    return math.fract(h1 + t * (h2m - h1));
}

/// -> (hue in turns [0, 1), saturation, value).
pub inline fn rgbToHsv(c: Vec3f32) Vec3f32 {
    const maxc = @max(c[0], @max(c[1], c[2]));
    const minc = @min(c[0], @min(c[1], c[2]));
    const delta = maxc - minc;

    var h: f32 = 0.0;
    if (delta > math.EPSILON) {
        if (maxc == c[0]) {
            h = (c[1] - c[2]) / delta;
            if (c[1] < c[2]) {
                h += 6.0;
            }
        } else if (maxc == c[1]) {
            h = ((c[2] - c[0]) / delta) + 2.0;
        } else {
            h = ((c[0] - c[1]) / delta) + 4.0;
        }
        h /= 6.0;
    }

    var s: f32 = 0.0;
    if (maxc > math.EPSILON) {
        s = delta / maxc;
    }
    return .{ h, s, maxc };
}

/// (hue in turns, saturation, value) -> rgb.
pub inline fn hsvToRgb(c: Vec3f32) Vec3f32 {
    const h = math.fract(c[0]) * 6.0;
    const s = c[1];
    const v = c[2];
    const i: i32 = @intFromFloat(@floor(h));
    const f = h - @floor(h);
    const p = v * (1.0 - s);
    const q = v * (1.0 - s * f);
    const t = v * (1.0 - s * (1.0 - f));

    return switch (i) {
        0 => .{ v, t, p },
        1 => .{ q, v, p },
        2 => .{ p, v, t },
        3 => .{ p, q, v },
        4 => .{ t, p, v },
        else => .{ v, p, q },
    };
}

test "hsv round-trips" {
    const testing = @import("std").testing;
    const inputs = [4]Vec3f32{
        .{ 1.0, 0.0, 0.0 },
        .{ 0.2, 0.6, 0.9 },
        .{ 0.5, 0.5, 0.5 },
        .{ 0.0, 0.0, 0.0 },
    };
    for (inputs) |rgb| {
        const round_tripped = hsvToRgb(rgbToHsv(rgb));
        inline for (0..3) |i| try testing.expectApproxEqAbs(rgb[i], round_tripped[i], 1e-5);
    }
}

test "linearToSrgb follows the piecewise sRGB curve" {
    const testing = @import("std").testing;
    // linear piece below the 0.0031308 breakpoint
    try testing.expectApproxEqAbs(@as(f32, 0.0), linearToSrgb(0.0), 1e-7);
    try testing.expectApproxEqAbs(@as(f32, 0.01292), linearToSrgb(0.001), 1e-7);
    // power piece above it: 0.04045 linear is 0.22221 sRGB
    try testing.expectApproxEqAbs(@as(f32, 0.2222055), linearToSrgb(0.04045), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), linearToSrgb(1.0), 1e-6);
}
