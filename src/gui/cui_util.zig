//! Small helpers for the CUI-based GUI: size constructors, C strings and
//! theme tokens.

const std = @import("std");
const cui = @import("cui");

pub fn zero(comptime T: type) T {
    return std.mem.zeroes(T);
}

pub fn fit() cui.cui_size {
    return .{ .kind = @intCast(cui.CUI_SIZE_FIT), .value = 0 };
}

pub fn fill() cui.cui_size {
    return .{ .kind = @intCast(cui.CUI_SIZE_GROW), .value = 1 };
}

pub fn px(value: f32) cui.cui_size {
    return .{ .kind = @intCast(cui.CUI_SIZE_FIXED), .value = value };
}

/// NUL-terminated view of `text` in `buf`. Valid until the next use of `buf`.
pub fn zs(buf: []u8, text: []const u8) [*c]const u8 {
    const out = std.mem.printSentinel(buf, "{s}", .{text}, 0) catch return "";
    return out.ptr;
}

pub fn z(buf: []u8, comptime fmt: []const u8, args: anytype) [*c]const u8 {
    const out = std.mem.printSentinel(buf, fmt, args, 0) catch return "";
    return out.ptr;
}

pub fn token(ui: *cui.cui_ctx, t: c_int) cui.cui_color {
    return cui.cui_token_color(ui, @intCast(t));
}

/// Per-view string storage. CUI's node editor (and some components) keep the
/// char pointers until `cui_end_frame`, after the draw functions have returned,
/// so dynamic labels must outlive the call. Reset at the start of the next
/// draw, once the previous frame has been painted.
pub const FrameStrings = struct {
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) FrameStrings {
        return .{ .arena = .init(allocator) };
    }

    pub fn deinit(self: *FrameStrings) void {
        self.arena.deinit();
    }

    pub fn reset(self: *FrameStrings) void {
        _ = self.arena.reset(.retain_capacity);
    }

    pub fn alloc(self: *FrameStrings, text: []const u8) ![:0]u8 {
        const out = try self.arena.allocator().allocSentinel(u8, text.len, 0);
        @memcpy(out, text);
        return out;
    }

    pub fn fmt(self: *FrameStrings, comptime format: []const u8, args: anytype) ![:0]u8 {
        var buf: [1024]u8 = undefined;
        const text_z = std.mem.printSentinel(&buf, format, args, 0) catch return error.NoSpaceLeft;
        return self.alloc(text_z);
    }
};
