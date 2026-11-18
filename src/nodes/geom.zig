//! Geometry for the node graph: vectors, rectangles and the cubic bezier
//! used to draw and hit-test links. No ImGui dependency, so the math is
//! unit-testable without a graphics context.

const std = @import("std");

pub const Vec2 = struct {
    x: f32 = 0,
    y: f32 = 0,

    pub fn init(x: f32, y: f32) Vec2 {
        return .{ .x = x, .y = y };
    }

    pub fn add(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }

    pub fn sub(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }

    pub fn scale(a: Vec2, s: f32) Vec2 {
        return .{ .x = a.x * s, .y = a.y * s };
    }

    pub fn dot(a: Vec2, b: Vec2) f32 {
        return a.x * b.x + a.y * b.y;
    }

    pub fn lengthSquared(a: Vec2) f32 {
        return a.dot(a);
    }

    pub fn length(a: Vec2) f32 {
        return @sqrt(a.lengthSquared());
    }

    pub fn distanceSquared(a: Vec2, b: Vec2) f32 {
        return a.sub(b).lengthSquared();
    }

    pub fn distance(a: Vec2, b: Vec2) f32 {
        return a.sub(b).length();
    }
};

pub const Rect = struct {
    min: Vec2 = .{},
    max: Vec2 = .{},

    pub fn fromPosSize(pos: Vec2, extent: Vec2) Rect {
        return .{ .min = pos, .max = pos.add(extent) };
    }

    pub fn size(r: Rect) Vec2 {
        return r.max.sub(r.min);
    }

    pub fn contains(r: Rect, p: Vec2) bool {
        return p.x >= r.min.x and p.y >= r.min.y and p.x <= r.max.x and p.y <= r.max.y;
    }

    pub fn overlaps(a: Rect, b: Rect) bool {
        return a.min.x <= b.max.x and a.max.x >= b.min.x and
            a.min.y <= b.max.y and a.max.y >= b.min.y;
    }

    pub fn translate(r: Rect, offset: Vec2) Rect {
        return .{ .min = r.min.add(offset), .max = r.max.add(offset) };
    }

    pub fn expand(r: Rect, amount: f32) Rect {
        return .{
            .min = .{ .x = r.min.x - amount, .y = r.min.y - amount },
            .max = .{ .x = r.max.x + amount, .y = r.max.y + amount },
        };
    }

    pub fn normalized(a: Vec2, b: Vec2) Rect {
        return .{
            .min = .{ .x = @min(a.x, b.x), .y = @min(a.y, b.y) },
            .max = .{ .x = @max(a.x, b.x), .y = @max(a.y, b.y) },
        };
    }
};

/// Point on a cubic bezier at `t` in `[0, 1]`.
pub fn bezierPoint(p0: Vec2, p1: Vec2, p2: Vec2, p3: Vec2, t: f32) Vec2 {
    const u = 1.0 - t;
    const uu = u * u;
    const tt = t * t;
    const a = uu * u;
    const b = 3.0 * uu * t;
    const c = 3.0 * u * tt;
    const d = tt * t;
    return .{
        .x = a * p0.x + b * p1.x + c * p2.x + d * p3.x,
        .y = a * p0.y + b * p1.y + c * p2.y + d * p3.y,
    };
}

/// Distance from `p` to the segment `a`-`b`.
pub fn pointSegmentDistance(p: Vec2, a: Vec2, b: Vec2) f32 {
    const ab = b.sub(a);
    const len_sq = ab.lengthSquared();
    if (len_sq <= std.math.floatEps(f32)) return p.distance(a);
    const t = std.math.clamp(p.sub(a).dot(ab) / len_sq, 0.0, 1.0);
    return p.distance(a.add(ab.scale(t)));
}

/// Approximate distance from `p` to a cubic bezier, by sampling it into
/// straight segments. Used for link hover/click hit-testing.
pub fn bezierDistance(p0: Vec2, p1: Vec2, p2: Vec2, p3: Vec2, p: Vec2) f32 {
    const segments = 24;
    var best: f32 = std.math.floatMax(f32);
    var prev = p0;
    var i: u32 = 1;
    while (i <= segments) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments));
        const next = bezierPoint(p0, p1, p2, p3, t);
        best = @min(best, pointSegmentDistance(p, prev, next));
        prev = next;
    }
    return best;
}

/// Control points for a left-to-right link: leave the output horizontally and
/// arrive at the input horizontally, scaled by the horizontal distance.
pub fn linkControls(from: Vec2, to: Vec2) [2]Vec2 {
    const dx = @abs(to.x - from.x);
    const slack = std.math.clamp(dx * 0.5, 24.0, 160.0);
    return .{
        .{ .x = from.x + slack, .y = from.y },
        .{ .x = to.x - slack, .y = to.y },
    };
}

test "vec2 arithmetic" {
    const a = Vec2.init(1, 2);
    const b = Vec2.init(4, 6);
    const d = a.sub(b);
    try std.testing.expectEqual(@as(f32, -3), d.x);
    try std.testing.expectEqual(@as(f32, 5), b.distance(a));
}

test "rect contains and overlaps" {
    const r = Rect.fromPosSize(.{ .x = 10, .y = 10 }, .{ .x = 20, .y = 20 });
    try std.testing.expect(r.contains(.{ .x = 15, .y = 15 }));
    try std.testing.expect(!r.contains(.{ .x = 31, .y = 15 }));
    try std.testing.expect(r.overlaps(Rect.fromPosSize(.{ .x = 29, .y = 0 }, .{ .x = 10, .y = 10 })));
    try std.testing.expect(!r.overlaps(Rect.fromPosSize(.{ .x = 31, .y = 0 }, .{ .x = 10, .y = 10 })));
}

test "bezier endpoints and distance" {
    const p0 = Vec2.init(0, 0);
    const p1 = Vec2.init(10, 0);
    const p2 = Vec2.init(10, 10);
    const p3 = Vec2.init(20, 10);
    const start = bezierPoint(p0, p1, p2, p3, 0);
    const end = bezierPoint(p0, p1, p2, p3, 1);
    try std.testing.expectEqual(@as(f32, 0), start.x);
    try std.testing.expectEqual(@as(f32, 20), end.x);
    // a point on the curve is closer than a point far away
    const on = bezierPoint(p0, p1, p2, p3, 0.5);
    try std.testing.expect(bezierDistance(p0, p1, p2, p3, on) < 0.01);
    const far = on.add(.{ .x = 0, .y = 100 });
    try std.testing.expect(bezierDistance(p0, p1, p2, p3, far) > 50);
}
