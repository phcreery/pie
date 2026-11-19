//! Reusable f32 color math: sRGB transfer function, OkLab/OkLCh, and the
//! Weibull "film curve" (plain and AGX-flavoured).
//!
//! Shared by shaders (`@import("shader").math.color`) and CPU-side module code.

const std = @import("std");
const math = @import("root.zig");
pub const matrices = @import("matrices.zig"); // color matrices, exported as `math.matrices`

const Vec3 = math.as(f32).Vec3;

// ---------------------------------------------------------------------------
// sRGB transfer function (IEC 61966-2-1)
// ---------------------------------------------------------------------------

/// Linear -> sRGB encoded.
pub inline fn linearToSrgb(c: f32) f32 {
    if (c <= 0.0031308) return c * 12.92;
    return 1.055 * math.powf(c, 1.0 / 2.4) - 0.055;
}

pub inline fn linearToSrgbVec3(v: Vec3) Vec3 {
    return Vec3.new(linearToSrgb(v.x), linearToSrgb(v.y), linearToSrgb(v.z));
}

// ---------------------------------------------------------------------------
// OkLab / OkLCh (linear Rec.2020)
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

/// Linear Rec.2020 -> OkLab. Matches vkdt's `rec2020_to_oklab`.
pub inline fn rec2020ToOklab(rgb: Vec3) Vec3 {
    var lms = matrices.oklab_lms_from_rec2020.mulVec(rgb);
    lms = Vec3.new(
        math.powf(@max(lms.x, 0.0), 1.0 / 3.0),
        math.powf(@max(lms.y, 0.0), 1.0 / 3.0),
        math.powf(@max(lms.z, 0.0), 1.0 / 3.0),
    );
    return matrices.oklab_from_lms.mulVec(lms);
}

/// OkLab -> linear Rec.2020.
pub inline fn oklabToRec2020(lab: Vec3) Vec3 {
    var lms = matrices.lms_from_oklab.mulVec(lab);
    lms = Vec3.new(lms.x * lms.x * lms.x, lms.y * lms.y * lms.y, lms.z * lms.z * lms.z);
    return matrices.rec2020_from_lms.mulVec(lms);
}

/// Linear Rec.2020 -> OkLCh, packed as (hue in turns, chroma, lightness).
///
/// This is the space vkdt's `rgb2hsv` actually uses in the AgX path: hue is
/// mixed in OkLab, not in classic HSV.
pub inline fn rec2020ToOklch(rgb: Vec3) Vec3 {
    const lab = rec2020ToOklab(rgb);
    if (lab.x <= 0.0) return Vec3.zero;
    const hue = math.fract(1.0 + math.atan2(lab.z, lab.y) / (2.0 * std.math.pi));
    return Vec3.new(hue, @sqrt(lab.y * lab.y + lab.z * lab.z), lab.x);
}

/// (hue in turns, chroma, lightness) -> linear Rec.2020.
pub inline fn oklchToRec2020(hcl: Vec3) Vec3 {
    const lab = Vec3.new(
        hcl.z,
        hcl.y * @cos(2.0 * std.math.pi * hcl.x),
        hcl.y * @sin(2.0 * std.math.pi * hcl.x),
    );
    if (lab.x <= 0.0) return Vec3.zero;
    return oklabToRec2020(lab);
}

test "oklab round-trips and neutral gray has zero chroma" {
    const testing = @import("std").testing;
    const inputs = [5]Vec3{
        Vec3.new(1.0, 0.0, 0.0),
        Vec3.new(0.2, 0.6, 0.9),
        Vec3.new(0.18, 0.18, 0.18),
        Vec3.new(0.4, 0.2, 0.1),
        Vec3.new(0.0, 0.0, 0.0),
    };
    for (inputs) |rgb| {
        const round_tripped = oklabToRec2020(rec2020ToOklab(rgb));
        try testing.expectApproxEqAbs(rgb.x, round_tripped.x, 1e-4);
        try testing.expectApproxEqAbs(rgb.y, round_tripped.y, 1e-4);
        try testing.expectApproxEqAbs(rgb.z, round_tripped.z, 1e-4);
    }

    const gray = rec2020ToOklch(Vec3.new(0.18, 0.18, 0.18));
    try testing.expectApproxEqAbs(@as(f32, 0.0), gray.y, 1e-3);
    // OkLab L of a neutral is cbrt(linear value)
    try testing.expectApproxEqAbs(@as(f32, 0.56462), gray.z, 1e-3);
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
