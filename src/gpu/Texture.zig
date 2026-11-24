const std = @import("std");
const wgpu = @import("wgpu_zig");
const gpu_types = @import("types.zig");
const ROI = gpu_types.ROI;
const Resource = gpu_types.Resource;
const DataType = gpu_types.DataType;
const GPU = @import("GPU.zig");

const slog = std.log.scoped(.gpu);

texture: wgpu.Texture,
resource: Resource,
datatype: DataType,
roi: ROI,

const Self = @This();

/// Map a socket resource and datatype to the WebGPU texture format. Buffers
/// and wildcards have no texture representation.
pub fn toWGPUFormat(resource: Resource, datatype: DataType) !wgpu.Texture.Format {
    return switch (resource) {
        .rgba => switch (datatype) {
            .f16 => .rgba16_float,
            .u16 => .rgba16_uint,
            .f32 => .rgba32_float,
            .u32 => .rgba32_uint,
            .i32 => .rgba32_sint,
            .u8, .any => error.UnsupportedFormat,
        },
        .r, .rggb => switch (datatype) {
            .u8 => .r8_uint,
            .u16 => .r16_uint,
            .f16 => .r16_float,
            .f32 => .r32_float,
            .u32 => .r32_uint,
            .i32 => .r32_sint,
            .any => error.UnsupportedFormat,
        },
        .buffer => error.NotATexture,
        .any => error.UnresolvedFormat,
    };
}

/// The bind-group sample type for a readable texture.
pub fn toWGPUSampleType(resource: Resource, datatype: DataType) !wgpu.BindGroupLayout.TextureSampleType {
    return switch (resource) {
        .rgba => switch (datatype) {
            .f16 => .float,
            .u16, .u32 => .uint,
            .i32 => .sint,
            .f32 => .unfilterable_float,
            .u8, .any => error.UnsupportedFormat,
        },
        .r, .rggb => switch (datatype) {
            .u8, .u16, .u32 => .uint,
            .i32 => .sint,
            .f16 => .float,
            // r32_float is not filterable in WebGPU, so it must bind as an
            // unfilterable-float sample type.
            .f32 => .unfilterable_float,
            .any => error.UnsupportedFormat,
        },
        .buffer => error.NotATexture,
        .any => error.UnresolvedFormat,
    };
}

pub fn init(gpu: *GPU, name: []const u8, resource: Resource, datatype: DataType, roi: ROI) !Self {
    slog.debug("Creating texture {s}/{s} of size {d}x{d}", .{ @tagName(resource), @tagName(datatype), roi.w, roi.h });

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
        .format = try toWGPUFormat(resource, datatype),
        .usage = usage,
    });
    errdefer texture.deinit();
    return Self{
        .texture = texture,
        .resource = resource,
        .datatype = datatype,
        .roi = roi,
    };
}

pub fn deinit(self: *Self) void {
    self.texture.deinit();
}
