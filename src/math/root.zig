pub const matrices = @import("matrices.zig");
pub const color = @import("color.zig");

pub const zlm = @import("zlm/zlm.zig");

const math_f32 = zlm.as(f32);

/// Constructors: `vec3(x, y, z)` is `Vec3.new(x, y, z)`.
pub const vec2 = math_f32.vec2;
pub const vec3 = math_f32.vec3;
pub const vec4 = math_f32.vec4;

pub const Vec2 = math_f32.Vec2;
pub const Vec3 = math_f32.Vec3;
pub const Vec4 = math_f32.Vec4;
pub const Mat3 = math_f32.Mat3;
pub const Mat4 = math_f32.Mat4;

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

test {
    _ = zlm;
    _ = matrices;
    _ = color;
}
