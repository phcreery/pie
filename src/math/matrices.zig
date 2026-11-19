//! Named 3x3 color matrices, row-major (`Mat3.fields[row][col]`).

const Mat3 = @import("root.zig").as(f32).Mat3;

/// CIE XYZ (D65) -> linear sRGB (Rec.709 primaries, D65).
/// Bruce Lindbloom's published sRGB D65 matrix
/// http://www.brucelindbloom.com/index.html?Eqn_RGB_XYZ_Matrix.html
pub const srgb_from_xyz = Mat3{ .fields = .{
    .{ 3.2404542, -1.5371385, -0.4985314 },
    .{ -0.9692660, 1.8760108, 0.0415560 },
    .{ 0.0556434, -0.2040259, 1.0572252 },
} };

// XYZ //

pub const xyz_from_rec2020 = Mat3{ .fields = .{
    .{ 0.636958048301290991, 0.144616903586208406, 0.168880975164172054 },
    .{ 0.26270021201126692, 0.677998071518871148, 0.0593017164698619384 },
    .{ 4.9999999999999999e-17, 0.0280726930490874452, 1.06098505771079066 },
} };
pub const rec2020_from_xyz_d65 = Mat3{ .fields = .{
    .{ 1.71665119, -0.35567078, -0.25336628 },
    .{ -0.66668435, 1.61648124, 0.01576855 },
    .{ 0.01763986, -0.04277061, 0.94210312 },
} };

// linear sRGB //

/// linear sRGB (Rec.709 primaries, D65) -> linear Rec.2020.
pub const rec2020_from_srgb = Mat3{ .fields = .{
    .{ 0.6274083694, 0.3292853862, 0.0433133745 },
    .{ 0.0690961995, 0.9195258911, 0.0113621363 },
    .{ 0.0163938775, 0.0880264019, 0.8957284939 },
} };

/// linear Rec.2020 -> linear sRGB (Rec.709 primaries, D65).
pub const srgb_from_rec2020 = Mat3{ .fields = .{
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
            try testing.expectApproxEqAbs(expected, product.fields[r][c], 1e-6);
        }
    }
}

/// AgX inset and outset constants
/// generated from https://github.com/EaryChow/AgX_LUT_Gen/blob/main/AgXBaseRec2020.py
pub const agx_inset = Mat3{ .fields = .{
    .{ 0.856627153315983, 0.0951212405381588, 0.0482516061458583 },
    .{ 0.137318972929847, 0.761241990602591, 0.101439036467562 },
    .{ 0.11189821299995, 0.0767994186031903, 0.811302368396859 },
} };
pub const agx_inset_inv = Mat3{ .fields = .{
    .{ 1.1271005818144368, -0.11060664309660323, -0.016493938717834573 },
    .{ -0.1413297634984383, 1.157823702216272, -0.016493938717834257 },
    .{ -0.14132976349843826, -0.11060664309660294, 1.2519364065950405 },
} };

test "agx matrices preserve neutral gray" {
    const testing = @import("std").testing;
    for ([_]Mat3{ agx_inset, agx_inset_inv }) |m| {
        inline for (0..3) |r| {
            try testing.expectApproxEqAbs(@as(f32, 1.0), m.fields[r][0] + m.fields[r][1] + m.fields[r][2], 1e-6);
        }
    }
}

// OkLab (Björn Ottosson), combined with the Rec.2020 linear RGB -> XYZ and
// XYZ -> LMS matrices, as used by vkdt's colourspaces.glsl. Row-major.
pub const oklab_lms_from_rec2020 = Mat3{ .fields = .{
    .{ 0.61668844, 0.36015907, 0.02304329 },
    .{ 0.2651402, 0.63585648, 0.09903023 },
    .{ 0.10015065, 0.20400432, 0.69632468 },
} };
pub const oklab_from_lms = Mat3{ .fields = .{
    .{ 0.21045426, 0.79361779, -0.00407205 },
    .{ 1.9779985, -2.42859221, 0.45059371 },
    .{ 0.02590404, 0.78277177, -0.80867577 },
} };
pub const lms_from_oklab = Mat3{ .fields = .{
    .{ 1.0, 0.39633779, 0.21580376 },
    .{ 1.00000001, -0.10556134, -0.06385417 },
    .{ 1.00000005, -0.08948418, -1.29148554 },
} };
pub const rec2020_from_lms = Mat3{ .fields = .{
    .{ 2.14014041, -1.24635595, 0.10643173 },
    .{ -0.88483245, 2.16317272, -0.27836159 },
    .{ -0.04857906, -0.45449091, 1.50235629 },
} };
