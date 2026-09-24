//! Named 3x3 color matrices, row-major (`mat3.zig` documents the convention).

const mat3 = @import("mat3.zig");

/// linear sRGB (Rec.709 primaries, D65) -> linear Rec.2020.
pub const srgb_to_rec2020 = mat3.Mat3f32{ .rows = .{
    .{ 0.6274083694, 0.3292853862, 0.0433133745 },
    .{ 0.0690961995, 0.9195258911, 0.0113621363 },
    .{ 0.0163938775, 0.0880264019, 0.8957284939 },
} };

/// linear Rec.2020 -> linear sRGB (Rec.709 primaries, D65).
/// Exact inverse of `srgb_to_rec2020` to the printed precision.
pub const rec2020_to_srgb = mat3.Mat3f32{ .rows = .{
    .{ 1.6604791628, -0.5876504078, -0.0728390268 },
    .{ -0.1245495865, 1.1329177667, -0.0083481806 },
    .{ -0.0181506339, -0.1005804845, 1.1185632490 },
} };

/// AgX inset and outset constants
/// generated from https://github.com/EaryChow/AgX_LUT_Gen/blob/main/AgXBaseRec2020.py
pub const agx_inset = mat3.Mat3f32{ .rows = .{
    .{ 0.856627153315983, 0.137318972929847, 0.11189821299995 },
    .{ 0.0951212405381588, 0.761241990602591, 0.0767994186031903 },
    .{ 0.0482516061458583, 0.101439036467562, 0.811302368396859 },
} };
pub const agx_inset_inv = mat3.Mat3f32{ .rows = .{
    .{ 1.1271005818144368, -0.1413297634984383, -0.14132976349843826 },
    .{ -0.11060664309660323, 1.157823702216272, -0.11060664309660294 },
    .{ -0.016493938717834573, -0.016493938717834257, 1.2519364065950405 },
} };

test "srgb <-> rec2020 are inverses" {
    const testing = @import("std").testing;
    const product = srgb_to_rec2020.mul(rec2020_to_srgb);
    inline for (0..3) |r| {
        inline for (0..3) |c| {
            const expected: f32 = if (r == c) 1.0 else 0.0;
            try testing.expectApproxEqAbs(expected, product.rows[r][c], 1e-6);
        }
    }
}
