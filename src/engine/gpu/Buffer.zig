//! GPU allocator using an upload and download buffer for staging data to/from the GPU.
//! GPU must outlive Buffer
const std = @import("std");
const wgpu = @import("wgpu_zig");
const zuballoc = @import("zuballoc");
const ROI = @import("../ROI.zig");
const GPU = @import("GPU.zig");
const Texture = @import("Texture.zig");
const TextureFormat = Texture.TextureFormat;

const c = wgpu.c;
const slog = std.log.scoped(.gpu);

gpu: *GPU,
buffer: wgpu.Buffer,
buffer_size: u64,
memory_type: MemoryType,

const Self = @This();

pub const MemoryType = enum {
    upload,
    download,
    storage,
    uniform,

    pub fn toGPUBufferUsage(self: MemoryType) wgpu.Buffer.Usage {
        return switch (self) {
            .upload => .{ .copy_src = true, .map_write = true },
            .download => .{ .copy_dst = true, .map_read = true },
            .storage => .{ .copy_dst = true, .storage = true },
            .uniform => .{ .copy_dst = true, .uniform = true },
        };
    }

    pub fn toGPUMapMode(self: MemoryType) c_uint {
        return switch (self) {
            .upload => c.WGPUMapMode_Write,
            .download => c.WGPUMapMode_Read,
            .storage => c.WGPUMapMode_Write,
            .uniform => c.WGPUMapMode_Write,
        };
    }
};

/// size in bytes of the buffer
pub fn init(gpu: *GPU, size_bytes: ?u64, memory_type: MemoryType) !Self {
    var max_buffer_size: u64 = if (gpu.adapterLimits()) |limits|
        limits.maxBufferSize
    else
        std.math.maxInt(u64);

    if (max_buffer_size == std.math.maxInt(u64)) {
        // set to something reasonable
        max_buffer_size = 256 * 1024 * 1024 * 12; // 256 MB x12 for RGBAf16
    }

    if (size_bytes) |s| {
        if (s > max_buffer_size) {
            slog.err("Requested Buffer size {B:.4} exceeds max buffer size {B:.4}", .{ s, max_buffer_size });
            return error.InvalidInput;
        }
    }
    const buffer_size_bytes = size_bytes orelse (max_buffer_size / 16);

    // Finally we create a buffer which can be read by the CPU. This buffer is how we will read
    // the data. We need to use a separate buffer because we need to have a usage of `MAP_READ`,
    // and that usage can only be used with `COPY_DST`.
    slog.info("Creating Buffer with size {B:.4}", .{buffer_size_bytes});
    const buffer = try gpu.device.createBuffer(.{
        .label = "buffer",
        .usage = memory_type.toGPUBufferUsage(),
        .size = buffer_size_bytes,
        .mapped_at_creation = false,
    });
    errdefer buffer.deinit();

    return Self{
        .gpu = gpu,
        .buffer = buffer,
        .buffer_size = buffer_size_bytes,
        .memory_type = memory_type,
    };
}

pub fn deinit(self: *Self) void {
    self.buffer.deinit();
}

/// maps the buffer and returns a pointer to write to
pub fn mapSize(
    self: *Self,
    size_bytes: usize,
) *anyopaque {
    slog.debug("Mapping GPU buffer of size {B:.4}", .{size_bytes});

    // TODO: first check mapped status
    // https://github.com/gfx-rs/wgpu-native/blob/d8238888998db26ceab41942f269da0fa32b890c/src/unimplemented.rs#L25

    // We now map the buffer so we can write to it. Mapping tells wgpu that we want to read/write
    // to the buffer directly by the CPU and it should not permit any more GPU operations on the buffer.
    //
    // Mapping requires that the GPU be finished using the buffer before it resolves, so mapping has a callback
    // to tell you when the mapping is complete.
    var buffer_map_complete = false;
    _ = c.wgpuBufferMapAsync(self.buffer.buffer, self.memory_type.toGPUMapMode(), 0, size_bytes, .{
        .mode = c.WGPUCallbackMode_AllowSpontaneous,
        .callback = handleBufferMap,
        .userdata1 = @ptrCast(&buffer_map_complete),
    });

    slog.debug("Waiting for buffer map to complete", .{});

    // Wait for the GPU to finish working on the submitted work. wgpu-native
    // resolves the map callback from wgpuDevicePoll.
    while (!buffer_map_complete) {
        _ = self.gpu.device.poll(true);
    }

    slog.debug("Buffer map complete", .{});

    return c.wgpuBufferGetMappedRange(self.buffer.buffer, 0, size_bytes).?;
}

pub fn map(self: *Self) void {
    _ = self.mapSize(self.buffer_size);
}

pub fn unmap(
    self: *Self,
) void {
    self.buffer.unmap();
}

/// a simple wrapper around map + memcpy + unmap
pub fn upload(
    self: *Self,
    comptime T: type,
    data: []const T,
    comptime format: TextureFormat,
    roi: ROI,
) void {
    // print the first 4 values
    slog.debug("First 4 values to upload: {any}, {any}, {any}, {any}", .{ data[0], data[1], data[2], data[3] });

    const size_bytes = roi.w * roi.h * format.bpp();
    const upload_mapped_ptr: *anyopaque = self.mapSize(size_bytes);
    const upload_buffer_ptr: [*]T = @ptrCast(@alignCast(upload_mapped_ptr));
    const upload_buffer_slice = upload_buffer_ptr[0..(roi.w * roi.h * format.nchannels())];
    defer self.unmap();

    @memcpy(upload_buffer_slice, data);
}

// pub const BufferAllocator = std.heap.FixedBufferAllocator;
pub const Allocator = zuballoc.SubAllocator;

pub fn fixedBufferAllocator(self: *Self, gpa: std.mem.Allocator) !Allocator {
    // slog.debug("Buffer size: {d}", .{gpu_memory.buffer_size});
    const mapped_ptr: *anyopaque = self.mapSize(self.buffer_size);
    defer self.unmap();
    const buffer_ptr: [*]u8 = @ptrCast(@alignCast(mapped_ptr));
    const buffer_slice = buffer_ptr[0..@as(usize, self.buffer_size)];
    // const buf_allocator = std.heap.FixedBufferAllocator.init(buffer_slice);
    const buf_allocator = try zuballoc.SubAllocator.init(gpa, buffer_slice, 256);
    return buf_allocator;
}

/// Alternative mapUpload that writes directly to a texture
/// we aren't really using this now because there isn't an equivalent readTexture method
pub fn mapUploadTexture(
    self: *Self,
    comptime T: type,
    data: []const T,
    texture: Texture,
    comptime format: TextureFormat,
    roi: ROI,
) void {
    if (self.memory_type != .upload) {
        slog.err("Buffer.mapUploadTexture called on non-upload memory");
        return;
    }
    slog.debug("Writing data to GPU Texture", .{});

    const bytes_per_row = roi.w * format.bpp();
    self.gpu.queue.writeTexture(
        T,
        .{
            .texture = texture.texture,
            .mip_level = 0,
            .origin = .{ .x = 0, .y = 0, .z = 0 },
        },
        data,
        .{
            .offset = @as(u64, roi.y) * bytes_per_row + roi.x * format.bpp(),
            .bytes_per_row = bytes_per_row,
            .rows_per_image = roi.h,
        },
        .{
            .width = roi.w,
            .height = roi.h,
            .depth_or_array_layers = 1,
        },
    );
}

fn handleBufferMap(status: c.WGPUMapAsyncStatus, _: c.WGPUStringView, userdata1: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    // slog.debug("buffer_map status={x:.8}\n", .{@intFromEnum(status)});
    _ = status;
    const complete: *bool = @ptrCast(@alignCast(userdata1));
    complete.* = true;
}
