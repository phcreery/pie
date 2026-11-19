const std = @import("std");

pub const matrices = @import("matrices.zig");
pub const color = @import("color.zig");

pub const zlm = @import("zlm/zlm.zig");

// const math_f32 = zlm.as(f32);
pub const as = zlm.as;

/// Floor for values feeding `powf`/`log2` in `powf` and the curve.
pub const EPSILON: f32 = 1e-7;

/// `pow(base, exponent)` for a positive base.
///
/// Zig has no `pow` builtin and `std.math.pow` carries branches that do not
/// lower to SPIR-V; this is the definition of the GLSL.std.450 `Pow`
/// instruction (and WGSL `pow`): `exp2(exponent * log2(base))`.
pub inline fn powf(base: f32, exponent: f32) f32 {
    return @exp2(exponent * @log2(base));
}

/// Returns the fractional part of `x`. Equivalent to `x - floor(x)`.
pub inline fn fract(x: f32) f32 {
    return x - @floor(x);
}

/// `atan2(y, x)` usable from SPIR-V shaders.
///
/// `std.math.atan2` indexes constant slices at runtime, which the Zig SPIR-V
/// backend cannot lower. This uses the classic odd polynomial for `atan` on
/// `[0, 1]` (max error ~1e-5) plus quadrant correction.
pub inline fn atan2(y: f32, x: f32) f32 {
    const ax = @abs(x);
    const ay = @abs(y);
    if (ax == 0.0 and ay == 0.0) return 0.0;

    const z = if (ay <= ax) ay / ax else ax / ay;
    const z2 = z * z;
    var a = z * (0.9998660 + z2 * (-0.3302995 + z2 * (0.1801410 + z2 * (-0.0851330 + z2 * 0.0208351))));
    if (ay > ax) a = std.math.pi / 2.0 - a;
    if (x < 0.0) a = std.math.pi - a;
    return if (y < 0.0) -a else a;
}

test "atan2 matches std.math.atan2" {
    const testing = @import("std").testing;
    const points = [_][2]f32{
        .{ 1, 1 },     .{ 1, -1 },    .{ -1, 1 },     .{ -1, -1 },
        .{ 0, 1 },     .{ 0, -1 },    .{ 1, 0 },      .{ -1, 0 },
        .{ 0.2, 0.9 }, .{ 0.9, 0.2 }, .{ -0.3, 0.8 }, .{ 0.3, -0.8 },
        .{ 0.0, 0.0 },
    };
    for (points) |p| {
        const expected = std.math.atan2(p[0], p[1]);
        try testing.expectApproxEqAbs(expected, atan2(p[0], p[1]), 2e-4);
    }
}

test {
    _ = zlm;
    _ = matrices;
    _ = color;
}
