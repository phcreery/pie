//! 3-lane f32 vector helpers.
//!
//! `mat3.zig` re-exports `Vec3f32` from here, so `math` has exactly one
//! 3-vector type.

/// 3-component f32 vector.
pub const Vec3f32 = @Vector(3, f32);

/// Every lane set to `v`.
pub inline fn splat(v: f32) Vec3f32 {
    return @splat(v);
}

/// Component-wise reciprocal `1 / v`. Lanes must be non-zero.
pub inline fn recip(v: Vec3f32) Vec3f32 {
    return splat(1.0) / v;
}

/// Build from three scalars. Lane-wise on purpose: coercing the array to a
/// vector emits `OpCopyLogical`, which naga (the runtime SPIR-V validator)
/// rejects, so this is also the shader-safe path.
pub inline fn fromArray(arr: [3]f32) Vec3f32 {
    return .{ arr[0], arr[1], arr[2] };
}

test "splat and recip work lane-wise" {
    const testing = @import("std").testing;
    try testing.expectEqual(Vec3f32{ 2.0, 2.0, 2.0 }, splat(2.0));
    try testing.expectEqual(Vec3f32{ 0.5, 1.0, 0.25 }, recip(.{ 2.0, 1.0, 4.0 }));
}
