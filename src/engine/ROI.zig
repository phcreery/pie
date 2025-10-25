const ROI = @This();

size: struct {
    w: u32,
    h: u32,
},
origin: struct {
    x: u32,
    y: u32,
},

const Self = @This();

pub fn full(width: u32, height: u32) ROI {
    return ROI{
        .size = .{ .w = width, .h = height },
        .origin = .{ .x = 0, .y = 0 },
    };
}
pub fn div(self: Self, div_w: u32, div_h: u32) ROI {
    return ROI{
        .size = .{ .w = self.size.w / div_w, .h = self.size.h / div_h },
        .origin = .{ .x = self.origin.x / div_w, .y = self.origin.y / div_h },
    };
}

pub fn scaled(self: Self, scale_w: f32, scale_h: f32) ROI {
    return ROI{
        .size = .{
            .w = @as(u32, @intFromFloat(@as(f32, @floatFromInt(self.size.w)) * scale_w)),
            .h = @as(u32, @intFromFloat(@as(f32, @floatFromInt(self.size.h)) * scale_h)),
        },
        .origin = .{
            .x = @as(u32, @intFromFloat(@as(f32, @floatFromInt(self.origin.x)) * scale_w)),
            .y = @as(u32, @intFromFloat(@as(f32, @floatFromInt(self.origin.y)) * scale_h)),
        },
    };
}

pub fn splitH(self: Self) [2]ROI {
    return [_]ROI{
        ROI{
            .size = .{ .w = self.size.w, .h = self.size.h / 2 },
            .origin = .{ .x = self.origin.x, .y = self.origin.y },
        },
        ROI{
            .size = .{ .w = self.size.w, .h = self.size.h - (self.size.h / 2) },
            .origin = .{ .x = self.origin.x, .y = self.origin.y + (self.size.h / 2) },
        },
    };
}
