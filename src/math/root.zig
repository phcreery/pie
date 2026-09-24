pub const mat3 = @import("mat3.zig");
pub const matrices = @import("matrices.zig");
pub const color = @import("color.zig");

pub fn mat3x3Mul(C: anytype, A: anytype, B: anytype) void {
    const N = A.len;
    for (0..N) |i| {
        for (0..N) |j| {
            for (0..N) |k| {
                C[i][j] += A[i][k] * B[k][j];
            }
        }
    }
}

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

pub inline fn fract(x: f32) f32 {
    return x - @floor(x);
}

test {
    _ = mat3;
    _ = matrices;
    _ = color;
}
