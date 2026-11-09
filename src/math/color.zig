//! Reusable f32 color math: sRGB transfer function, HSV round-trip, and the
//! Weibull "film curve" (plain and AGX-flavoured).
//!
//! Shared by shaders (`@import("shader").math.color`) and CPU-side module code.

const math = @import("root.zig");
pub const matrices = @import("matrices.zig"); // color matrices, exported as `math.matrices`

const Vec3 = math.Vec3;

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
pub inline fn rgbToHsv(c: Vec3) Vec3 {
    const maxc = @max(c.x, @max(c.y, c.z));
    const minc = @min(c.x, @min(c.y, c.z));
    const delta = maxc - minc;

    var h: f32 = 0.0;
    if (delta > math.EPSILON) {
        if (maxc == c.x) {
            h = (c.y - c.z) / delta;
            if (c.y < c.z) {
                h += 6.0;
            }
        } else if (maxc == c.y) {
            h = ((c.z - c.x) / delta) + 2.0;
        } else {
            h = ((c.x - c.y) / delta) + 4.0;
        }
        h /= 6.0;
    }

    var s: f32 = 0.0;
    if (maxc > math.EPSILON) {
        s = delta / maxc;
    }
    return Vec3.new(h, s, maxc);
}

/// (hue in turns, saturation, value) -> rgb.
pub inline fn hsvToRgb(c: Vec3) Vec3 {
    const h = math.fract(c.x) * 6.0;
    const s = c.y;
    const v = c.z;
    const i: i32 = @intFromFloat(@floor(h));
    const f = h - @floor(h);
    const p = v * (1.0 - s);
    const q = v * (1.0 - s * f);
    const t = v * (1.0 - s * (1.0 - f));

    return switch (i) {
        0 => Vec3.new(v, t, p),
        1 => Vec3.new(q, v, p),
        2 => Vec3.new(p, v, t),
        3 => Vec3.new(p, q, v),
        4 => Vec3.new(t, p, v),
        else => Vec3.new(v, p, q),
    };
}

test "hsv round-trips" {
    const testing = @import("std").testing;
    const inputs = [4]Vec3{
        Vec3.new(1.0, 0.0, 0.0),
        Vec3.new(0.2, 0.6, 0.9),
        Vec3.new(0.5, 0.5, 0.5),
        Vec3.new(0.0, 0.0, 0.0),
    };
    for (inputs) |rgb| {
        const round_tripped = hsvToRgb(rgbToHsv(rgb));
        try testing.expectApproxEqAbs(rgb.x, round_tripped.x, 1e-5);
        try testing.expectApproxEqAbs(rgb.y, round_tripped.y, 1e-5);
        try testing.expectApproxEqAbs(rgb.z, round_tripped.z, 1e-5);
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
