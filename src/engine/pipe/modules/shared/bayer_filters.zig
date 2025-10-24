const std = @import("std");

pub const FilterColor = enum(u16) { R, G, B, G2 };

pub const BayerFilters = struct {
    // TODO: support patterns greater than 2x2
    pattern: [2][2]FilterColor,

    /// convert from libraw idata.filters (a 32 bit mask of indices of cdesc (typically 'RGBG'))
    /// see https://www.libraw.org/docs/API-datastruct-eng.html
    /// see also libraw/libraw.h COLOR and FC functions
    pub fn fromLibraw(idata_filters: u32) !BayerFilters {
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
                const color_code = (idata_filters >> shift) & 3;
                // NOTE: assuming a Libraw cdesc of "RGBG"
                const color = switch (color_code) {
                    0 => FilterColor.R,
                    1 => FilterColor.G,
                    2 => FilterColor.B,
                    3 => FilterColor.G2,
                    else => return error.InvalidFilterColor,
                };
                pattern[row][col] = color;
            }
        }
        return BayerFilters{
            .pattern = pattern,
        };
    }

    pub fn get(self: BayerFilters, row: usize, col: usize) FilterColor {
        return self.pattern[row % 2][col % 2];
    }

    pub fn asRGGBVec2Offsets(self: BayerFilters) [4][2]usize {
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
};

test "BayerFilters.fromLibraw()" {
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

    var filters = try BayerFilters.fromLibraw(0b11001100110011001100110011001100);
    try std.testing.expectEqual([2][2]FilterColor{
        .{ .R, .G2 },
        .{ .R, .G2 },
    }, filters.pattern);
    filters = try BayerFilters.fromLibraw(0xb4b4b4b4);
    try std.testing.expectEqual([2][2]FilterColor{
        .{ .R, .G },
        .{ .G2, .B },
    }, filters.pattern);
}

test "BayerFilters.asRGGBVec2Offsets()" {
    const filters = try BayerFilters.fromLibraw(0xb4b4b4b4);
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
