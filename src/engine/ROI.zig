x: u32 = 0,
y: u32 = 0,
w: u32 = 0,
h: u32 = 0,

const ROI = @This();

pub fn full(width: u32, height: u32) ROI {
    return ROI{
        .w = width,
        .h = height,
        .x = 0,
        .y = 0,
    };
}
pub fn div(self: ROI, div_w: u32, div_h: u32) ROI {
    return ROI{
        .x = self.x / div_w,
        .y = self.y / div_h,
        .w = self.w / div_w,
        .h = self.h / div_h,
    };
}

pub fn scaled(self: ROI, scale_w: f32, scale_h: f32) ROI {
    return ROI{
        .w = @as(u32, @intFromFloat(@as(f32, @floatFromInt(self.w)) * scale_w)),
        .h = @as(u32, @intFromFloat(@as(f32, @floatFromInt(self.h)) * scale_h)),
        .x = @as(u32, @intFromFloat(@as(f32, @floatFromInt(self.x)) * scale_w)),
        .y = @as(u32, @intFromFloat(@as(f32, @floatFromInt(self.y)) * scale_h)),
    };
}

pub fn dupe(self: ROI) ROI {
    return self.div(1, 1);
}

pub fn splitH(self: ROI) [2]ROI {
    return [_]ROI{
        ROI{
            .w = self.w,
            .h = self.h / 2,
            .x = self.x,
            .y = self.y,
        },
        ROI{
            .w = self.w,
            .h = self.h - (self.h / 2),
            .x = self.x,
            .y = self.y + (self.h / 2),
        },
    };
}
