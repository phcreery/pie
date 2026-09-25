//! Reusable f32 color math: sRGB transfer function, HSV round-trip, and the
//! Weibull "film curve" (plain and AGX-flavoured).
//!
//! Shared by shaders (`@import("shader").math.color`) and CPU-side module code.

const math = @import("root.zig");
const mat3 = @import("mat3.zig");
const matrices = @import("matrices.zig"); // color matrices, exported as `math.matrices`

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
// Linear light color space conversions (matrices in matrices.zig)
// ---------------------------------------------------------------------------

pub inline fn srgbToRec2020(rgb: Vec3f32) Vec3f32 {
    return matrices.srgb_to_rec2020.mulVec(rgb);
}

pub inline fn rec2020ToSrgb(rgb: Vec3f32) Vec3f32 {
    return matrices.rec2020_to_srgb.mulVec(rgb);
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
