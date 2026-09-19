pub const mat3 = @import("mat3.zig");

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
