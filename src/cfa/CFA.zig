const std = @import("std");
pub const FilterColor = enum(u16) { R, G, B, G2 };

const CFA = @This();

// TODO: support patterns greater than 2x2
pattern: [2][2]FilterColor,

/// function that checks if this is the index of the first G or the second G in cdesc
fn gIndex(cdesc: []const u8, color_idx: usize) usize {
    // count gs in cdesc up to color_idx
    var g_idx: usize = 0;
    for (0..color_idx) |i| {
        if (cdesc[i] == 'G') {
            g_idx += 1;
        }
    }
    return g_idx;
}

/// convert from libraw idata.filters (a 32 bit mask of indices of cdesc (typically 'RGBG'))
/// see https://www.libraw.org/docs/API-datastruct-eng.html
/// see also libraw/libraw.h COLOR and FC functions
pub fn fromLibraw(cdesc: []const u8, idata_filters: u32) !CFA {
    if (idata_filters < 1000) {
        // these are special patterns that libraw reserves for non-standard CFA layouts
        return error.UnsupportedFilterPattern;
    }

    var pattern: [2][2]FilterColor = undefined;
    for (0..2) |_row| {
        const row = @as(u5, @intCast(_row));
        for (0..2) |_col| {
            const col = @as(u5, @intCast(_col));
            // some unreadable bitshifting done by libraw
            const shift: u5 = (((row << 1 & 14) | (col & 1)) << 1);
            const color_idx = (idata_filters >> shift) & 3;
            const color_char = cdesc[color_idx];
            const color = switch (color_char) {
                'R' => FilterColor.R,
                'G' => blk: switch (gIndex(cdesc, color_idx)) {
                    0 => break :blk FilterColor.G,
                    else => break :blk FilterColor.G2,
                },
                'B' => FilterColor.B,
                else => return error.InvalidFilterColor,
            };
            pattern[row][col] = color;
        }
    }
    return CFA{
        .pattern = pattern,
    };
}

pub fn get(self: CFA, row: usize, col: usize) FilterColor {
    return self.pattern[row % 2][col % 2];
}

pub fn asRGGBVec2Offsets(self: CFA) [4][2]usize {
    var offsets: [4][2]usize = undefined;
    for (0..4) |i| {
        const row = i / 2;
        const col = i % 2;
        const color = self.pattern[row][col];
        switch (color) {
            .R => offsets[0] = .{ row, col },
            .G => offsets[1] = .{ row, col },
            .G2 => offsets[2] = .{ row, col },
            .B => offsets[3] = .{ row, col },
        }
    }
    return offsets;
}

test "CFA.fromLibraw()" {
    // 0b11001100110011001100110011001100
    //        the 4 colors are:  ^^^^^^^^
    // I think libraw reads from right-to-left
    // translates to
    // [ 00 11 ]
    // [ 00 11 ]
    // which is indices
    // [ 0 3 ]
    // [ 0 3 ]
    // which with a Libraw cdesc of "RGBG" maps to
    // [ R G2 ]
    // [ R G2 ]

    var filters = try CFA.fromLibraw("RGBG", 0b11001100110011001100110011001100);
    try std.testing.expectEqual([2][2]CFA.FilterColor{
        .{ .R, .G2 },
        .{ .R, .G2 },
    }, filters.pattern);
    filters = try CFA.fromLibraw("RGBG", 0xb4b4b4b4);
    try std.testing.expectEqual([2][2]CFA.FilterColor{
        .{ .R, .G },
        .{ .G2, .B },
    }, filters.pattern);
}

test "CFA.asRGGBVec2Offsets()" {
    const filters = try CFA.fromLibraw("RGBG", 0xb4b4b4b4);
    const rggb_offsets = filters.asRGGBVec2Offsets();
    try std.testing.expectEqual([4][2]usize{
        .{ 0, 0 },
        .{ 0, 1 },
        .{ 1, 0 },
        .{ 1, 1 },
    }, rggb_offsets);
    try std.testing.expectEqual([8]usize{
        0, 0,
        0, 1,
        1, 0,
        1, 1,
    }, @as([8]usize, @bitCast(rggb_offsets)));
}
