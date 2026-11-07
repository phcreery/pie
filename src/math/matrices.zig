//! Named 3x3 color matrices, row-major (`mat3.zig` documents the convention).

const mat3 = @import("mat3.zig");

/// CIE XYZ (D65) -> linear sRGB (Rec.709 primaries, D65).
/// Bruce Lindbloom's published sRGB D65 matrix
/// http://www.brucelindbloom.com/index.html?Eqn_RGB_XYZ_Matrix.html
pub const srgb_from_xyz = mat3.Mat3f32{ .rows = .{
    .{ 3.2404542, -1.5371385, -0.4985314 },
    .{ -0.9692660, 1.8760108, 0.0415560 },
    .{ 0.0556434, -0.2040259, 1.0572252 },
} };

// XYZ //

pub const xyz_from_rec2020 = mat3.Mat3f32{ .rows = .{
    .{ 0.636958048301290991, 0.144616903586208406, 0.168880975164172054 },
    .{ 0.26270021201126692, 0.677998071518871148, 0.0593017164698619384 },
    .{ 4.9999999999999999e-17, 0.0280726930490874452, 1.06098505771079066 },
} };
pub const rec2020_from_xyz_d65 = mat3.Mat3f32{ .rows = .{
    .{ 1.71665119, -0.35567078, -0.25336628 },
    .{ -0.66668435, 1.61648124, 0.01576855 },
    .{ 0.01763986, -0.04277061, 0.94210312 },
} };

// linear sRGB //

/// linear sRGB (Rec.709 primaries, D65) -> linear Rec.2020.
pub const rec2020_from_srgb = mat3.Mat3f32{ .rows = .{
    .{ 0.6274083694, 0.3292853862, 0.0433133745 },
    .{ 0.0690961995, 0.9195258911, 0.0113621363 },
    .{ 0.0163938775, 0.0880264019, 0.8957284939 },
} };

/// linear Rec.2020 -> linear sRGB (Rec.709 primaries, D65).
pub const srgb_from_rec2020 = mat3.Mat3f32{ .rows = .{
    .{ 1.6604791628, -0.5876504078, -0.0728390268 },
    .{ -0.1245495865, 1.1329177667, -0.0083481806 },
    .{ -0.0181506339, -0.1005804845, 1.1185632490 },
} };

test "srgb <-> rec2020 are inverses" {
    const testing = @import("std").testing;
    const product = rec2020_from_srgb.mul(srgb_from_rec2020);
    inline for (0..3) |r| {
        inline for (0..3) |c| {
            const expected: f32 = if (r == c) 1.0 else 0.0;
            try testing.expectApproxEqAbs(expected, product.rows[r][c], 1e-6);
        }
    }
}

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
