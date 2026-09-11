const std = @import("std");
const wgpu = @import("wgpu_zig");
const ROI = @import("../ROI.zig");
const GPU = @import("GPU.zig");
const TextureFormat = @import("TextureFormat.zig").TextureFormat;

const slog = std.log.scoped(.gpu);

texture: wgpu.Texture,
format: TextureFormat,
roi: ROI,

const Self = @This();

pub fn init(gpu: *GPU, name: []const u8, format: TextureFormat, roi: ROI) !Self {
    slog.debug("Creating texture {s} of size {d}x{d}", .{ @tagName(format), roi.w, roi.h });

    const usage: wgpu.Texture.Usage = .{
        .storage_binding = true,
        .texture_binding = true,
        .copy_src = true,
        .copy_dst = true,
    };
    // r16uint/float does not support storage binding if
    // WGPUNativeFeature TextureAdapterSpecificFormatFeatures is not set
    // and the adapter doesn't support it

    const texture = try gpu.device.createTexture(.{
        .label = name,
        .size = .{
            .width = roi.w,
            .height = roi.h,
            .depth_or_array_layers = 1,
        },
        .mip_level_count = 1,
        .sample_count = 1,
        .dimension = .@"2d",
        .format = format.toWGPUFormat(),
        .usage = usage,
    });
    errdefer texture.deinit();
    return Self{
        .texture = texture,
        .format = format,
        .roi = roi,
    };
}

pub fn deinit(self: *Self) void {
    self.texture.deinit();
}
