// Mat3 kept close to https://github.com/kooparse/zalgebra/blob/main/src/mat3.zig

/// 3-component f32 vector.
pub const Vec3f32 = @Vector(3, f32);

/// Row-major 3x3 matrix: `m.rows[r][c]` is row `r`, column `c`.
///
/// Row-major is the convention the color matrices in `matrices.zig` are written
/// in: `mulVec` is `dot(rows[r], v)` per component, so the *rows* are the output
/// basis vectors. GLSL/WGSL `mat3` literals are column-major — build those with
/// `fromColumns`.
pub fn Mat3(comptime T: type) type {
    return struct {
        rows: [3]@Vector(3, T),

        const Self = @This();

        pub const identity: Self = .{ .rows = .{
            .{ 1, 0, 0 },
            .{ 0, 1, 0 },
            .{ 0, 0, 1 },
        } };

        pub inline fn fromRows(rows: [3]@Vector(3, T)) Self {
            return .{ .rows = rows };
        }

        /// Column-major input, i.e. what a GLSL/WGSL `mat3(...)` literal means.
        pub inline fn fromColumns(cols: [3]@Vector(3, T)) Self {
            return fromRows(cols).transpose();
        }

        /// `[3][3]T` is the layout of the CPU-side helpers below.
        pub inline fn fromArray(data: [3][3]T) Self {
            return .{ .rows = .{
                .{ data[0][0], data[0][1], data[0][2] },
                .{ data[1][0], data[1][1], data[1][2] },
                .{ data[2][0], data[2][1], data[2][2] },
            } };
        }

        pub inline fn toArray(m: Self) [3][3]T {
            return .{
                .{ m.rows[0][0], m.rows[0][1], m.rows[0][2] },
                .{ m.rows[1][0], m.rows[1][1], m.rows[1][2] },
                .{ m.rows[2][0], m.rows[2][1], m.rows[2][2] },
            };
        }

        pub inline fn transpose(m: Self) Self {
            return .{ .rows = .{
                .{ m.rows[0][0], m.rows[1][0], m.rows[2][0] },
                .{ m.rows[0][1], m.rows[1][1], m.rows[2][1] },
                .{ m.rows[0][2], m.rows[1][2], m.rows[2][2] },
            } };
        }

        /// Matrix * column vector.
        pub inline fn mulVec(m: Self, v: @Vector(3, T)) @Vector(3, T) {
            return .{ dot3(m.rows[0], v), dot3(m.rows[1], v), dot3(m.rows[2], v) };
        }

        /// `a * b`. `b` is applied first: `a.mul(b).mulVec(v) == a.mulVec(b.mulVec(v))`.
        pub inline fn mul(a: Self, b: Self) Self {
            const c0 = b.column(0);
            const c1 = b.column(1);
            const c2 = b.column(2);
            return .{ .rows = .{
                .{ dot3(a.rows[0], c0), dot3(a.rows[0], c1), dot3(a.rows[0], c2) },
                .{ dot3(a.rows[1], c0), dot3(a.rows[1], c1), dot3(a.rows[1], c2) },
                .{ dot3(a.rows[2], c0), dot3(a.rows[2], c1), dot3(a.rows[2], c2) },
            } };
        }

        /// Calculate determinant of the given 3x3 matrix.
        pub fn det(m: Self) T {
            return m.rows[0][0] * (m.rows[1][1] * m.rows[2][2] - m.rows[1][2] * m.rows[2][1]) -
                m.rows[0][1] * (m.rows[1][0] * m.rows[2][2] - m.rows[1][2] * m.rows[2][0]) +
                m.rows[0][2] * (m.rows[1][0] * m.rows[2][1] - m.rows[1][1] * m.rows[2][0]);
        }

        /// Inverse by adjugate / determinant. Garbage for a singular matrix.
        /// Note: This is not the most efficient way to do this.
        /// TODO: Make it more efficient.
        pub fn inv(m: Self) Self {
            const d = 1 / m.det();

            return .{ .rows = .{
                .{
                    d * (m.rows[1][1] * m.rows[2][2] - m.rows[1][2] * m.rows[2][1]),
                    d * -(m.rows[0][1] * m.rows[2][2] - m.rows[0][2] * m.rows[2][1]),
                    d * (m.rows[0][1] * m.rows[1][2] - m.rows[0][2] * m.rows[1][1]),
                },
                .{
                    d * -(m.rows[1][0] * m.rows[2][2] - m.rows[1][2] * m.rows[2][0]),
                    d * (m.rows[0][0] * m.rows[2][2] - m.rows[0][2] * m.rows[2][0]),
                    d * -(m.rows[0][0] * m.rows[1][2] - m.rows[0][2] * m.rows[1][0]),
                },
                .{
                    d * (m.rows[1][0] * m.rows[2][1] - m.rows[1][1] * m.rows[2][0]),
                    d * -(m.rows[0][0] * m.rows[2][1] - m.rows[0][1] * m.rows[2][0]),
                    d * (m.rows[0][0] * m.rows[1][1] - m.rows[0][1] * m.rows[1][0]),
                },
            } };
        }

        inline fn column(m: Self, comptime c: usize) @Vector(3, T) {
            return .{ m.rows[0][c], m.rows[1][c], m.rows[2][c] };
        }

        /// Element-wise dot. Spelled out instead of `@reduce(.Add, a * b)` so the
        /// SPIR-V backend emits three FMAs rather than a 3-lane reduction.
        inline fn dot3(a: @Vector(3, T), b: @Vector(3, T)) T {
            return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
        }
    };
}

pub const Mat3f32 = Mat3(f32);

/// Calculate determinant of the given 3x3 matrix.
pub fn det(T: type, data: [3][3]T) T {
    return Mat3(T).fromArray(data).det();
}

/// Construct inverse 3x3 from given matrix.
pub fn inv(T: type, data: [3][3]T) [3][3]T {
    return Mat3(T).fromArray(data).inv().toArray();
}

const testing = @import("std").testing;

test "mulVec treats rows as basis vectors" {
    const m = Mat3f32.fromRows(.{
        .{ 1, 2, 3 },
        .{ 4, 5, 6 },
        .{ 7, 8, 9 },
    });
    // v = e0 selects the first *column*.
    try testing.expectEqual(Vec3f32{ 1, 4, 7 }, m.mulVec(.{ 1, 0, 0 }));
    try testing.expectEqual(Vec3f32{ 2, 5, 8 }, m.mulVec(.{ 0, 1, 0 }));
    try testing.expectEqual(Vec3f32{ 14, 32, 50 }, m.mulVec(.{ 1, 2, 3 }));
}

test "fromColumns is the transpose of fromRows" {
    const cols = [3]Vec3f32{
        .{ 1, 2, 3 },
        .{ 4, 5, 6 },
        .{ 7, 8, 9 },
    };
    const m = Mat3f32.fromColumns(cols);
    try testing.expectEqual(cols[0], m.mulVec(.{ 1, 0, 0 }));
    try testing.expectEqual(cols[1], m.mulVec(.{ 0, 1, 0 }));
    try testing.expectEqual(cols[2], m.mulVec(.{ 0, 0, 1 }));
}

test "mul composes like sequential mulVec" {
    const a = Mat3f32.fromRows(.{ .{ 1, 2, 3 }, .{ 0, 1, 4 }, .{ 5, 6, 0 } });
    const b = Mat3f32.fromRows(.{ .{ 2, 0, 1 }, .{ 1, 3, 0 }, .{ 0, 1, 2 } });
    const v = Vec3f32{ 1, 2, 3 };
    try testing.expectEqual(a.mulVec(b.mulVec(v)), a.mul(b).mulVec(v));
}

test "inv undoes mulVec" {
    const m = Mat3f32.fromRows(.{ .{ 2, 1, 0 }, .{ 1, 3, 1 }, .{ 0, 1, 4 } });
    const v = Vec3f32{ 1, 2, 3 };
    const round_tripped = m.inv().mulVec(m.mulVec(v));
    try testing.expectApproxEqAbs(v[0], round_tripped[0], 1e-5);
    try testing.expectApproxEqAbs(v[1], round_tripped[1], 1e-5);
    try testing.expectApproxEqAbs(v[2], round_tripped[2], 1e-5);
}

test "array helpers round-trip and agree with the methods" {
    const data = [3][3]f32{ .{ 2, 1, 0 }, .{ 1, 3, 1 }, .{ 0, 1, 4 } };
    try testing.expectEqual(data, Mat3f32.fromArray(data).toArray());
    try testing.expectApproxEqAbs(det(f32, data), Mat3f32.fromArray(data).det(), 1e-6);
    try testing.expectEqual(inv(f32, data), Mat3f32.fromArray(data).inv().toArray());
}
