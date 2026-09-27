//! Thin Zig wrapper over the vendored stb_image (v2.28).
//!
//! The C implementation is built as its own optimized static library
//! (`src/stbi/stb_image_impl.c`, see build.zig), so decoding stays fast even
//! when the importing module is compiled Debug. This wrapper exposes just the
//! entry points the engine uses; add more `extern` declarations as needed.

const std = @import("std");

// stb_image is linked as an optimized C library. Zig 0.17 dropped `@cImport`,
// so the declarations are spelled out here.
extern fn stbi_load_16(
    filename: [*c]const u8,
    x: *c_int,
    y: *c_int,
    channels_in_file: *c_int,
    desired_channels: c_int,
) [*c]u16;
extern fn stbi_image_free(retval: ?*anyopaque) void;
extern fn stbi_failure_reason() [*c]const u8;

/// A decoded image: tightly packed samples in the requested channel count.
pub const Image = struct {
    width: u32,
    height: u32,
    channels: u32,
    pixels: []u16,

    pub fn deinit(self: *Image, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.* = undefined;
    }
};

pub const DecodeError = error{
    PathTooLong,
    DecodeFailed,
    EmptyImage,
    OutOfMemory,
};

/// Why the last `decode16` failed, straight from stb_image.
pub fn failureReason() []const u8 {
    const reason = stbi_failure_reason();
    if (reason == null) return "unknown";
    return std.mem.span(@as([*:0]const u8, @ptrCast(reason)));
}

/// Decode `path` into 16-bit samples. 8-bit sources are scaled to 16-bit.
/// `desired_channels` may be 0 to keep the file's channel count.
pub fn decode16(
    allocator: std.mem.Allocator,
    path: []const u8,
    desired_channels: c_int,
) DecodeError!Image {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_z = std.mem.printSentinel(&path_buf, "{s}", .{path}, 0) catch return error.PathTooLong;

    var width: c_int = 0;
    var height: c_int = 0;
    var channels_in_file: c_int = 0;
    const data = stbi_load_16(path_z.ptr, &width, &height, &channels_in_file, desired_channels);
    if (data == null) return error.DecodeFailed;
    defer stbi_image_free(@ptrCast(data));
    if (width <= 0 or height <= 0) return error.EmptyImage;

    const channels: u32 = if (desired_channels > 0) @intCast(desired_channels) else @intCast(channels_in_file);
    const count = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * @as(usize, channels);
    const pixels = try allocator.alloc(u16, count);
    @memcpy(pixels, data[0..count]);

    return .{
        .width = @intCast(width),
        .height = @intCast(height),
        .channels = channels,
        .pixels = pixels,
    };
}
