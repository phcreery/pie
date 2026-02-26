/// A lot of this is just a wrapper around wgpu to make it easier to use in the context of image processing.
const std = @import("std");
const wgpu = @import("wgpu");
const gpu_data = @import("gpu_data.zig");
const ROI = @import("ROI.zig");
const zuballoc = @import("zuballoc");

const slog = std.log.scoped(.gpu);

// Copy error Buffer offset 4 is not aligned to block size or `COPY_BUFFER_ALIGNMENT`
// https://github.com/gfx-rs/wgpu/blob/trunk/wgpu-types/src/lib.rs#L96
// const COPY_BUFFER_ALIGNMENT: u64 = 4; //
pub const COPY_BUFFER_ALIGNMENT: std.mem.Alignment = .@"8";
const COPY_BYTES_PER_ROW_ALIGNMENT: u32 = 256; // wgpu.COPY_BYTES_PER_ROW_ALIGNMENT

pub const MAX_BIND_GROUPS: usize = 4;
pub const MAX_BINDINGS: usize = 8;

// Workgroup size must match the compute shader
pub const WORKGROUP_SIZE_X: u32 = 8;
pub const WORKGROUP_SIZE_Y: u32 = 8;
pub const WORKGROUP_SIZE_Z: u32 = 1;

pub const layoutStruct = gpu_data.layoutStruct;
// pub const layoutTaggedUnion = gpu_data.layoutTaggedUnion;
// pub const ParamValueTag = gpu_data.ParamValueTag;
// pub const ParamValue = gpu_data.ParamValue;

fn handleBufferMap(status: wgpu.MapAsyncStatus, _: wgpu.StringView, userdata1: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    // slog.debug("buffer_map status={x:.8}\n", .{@intFromEnum(status)});
    _ = status;
    const complete: *bool = @ptrCast(@alignCast(userdata1));
    complete.* = true;
}

pub const MemoryType = enum {
    upload,
    download,
    storage,
    uniform,

    pub fn toGPUBufferUsage(self: MemoryType) wgpu.BufferUsage {
        return switch (self) {
            .upload => wgpu.BufferUsages.copy_src | wgpu.BufferUsages.map_write,
            .download => wgpu.BufferUsages.copy_dst | wgpu.BufferUsages.map_read,
            .storage => wgpu.BufferUsages.copy_dst | wgpu.BufferUsages.storage,
            .uniform => wgpu.BufferUsages.copy_dst | wgpu.BufferUsages.uniform,
            // else => unreachable,
        };
    }

    pub fn toGPUMapMode(self: MemoryType) wgpu.MapMode {
        return switch (self) {
            .upload => wgpu.MapModes.write,
            .download => wgpu.MapModes.read,
            .storage => wgpu.MapModes.write,
            .uniform => wgpu.MapModes.write,
            // else => unreachable,
        };
    }
};

/// Dead simple GPU allocator using an upload and download buffer
/// for staging data to/from the GPU.
/// This is not optimal, but it works for now. Only one allocation at a time.
/// Future work could include a more complex allocator with multiple buffers
/// useful for multiple simultaneous operations.
/// GPU must outlive Buffer
pub const Buffer = struct {
    gpu: *GPU,
    buffer: *wgpu.Buffer,
    buffer_size: u64,
    memory_type: MemoryType,

    const Self = @This();

    /// size in bytes of the buffer
    pub fn init(gpu: *GPU, size_bytes: ?u64, memory_type: MemoryType) !Self {
        var limits = wgpu.Limits{};
        _ = gpu.adapter.getLimits(&limits);

        var max_buffer_size = limits.max_buffer_size;
        if (max_buffer_size == wgpu.WGPU_LIMIT_U64_UNDEFINED) {
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
        const buffer = gpu.device.createBuffer(&wgpu.BufferDescriptor{
            .label = wgpu.StringView.fromSlice("buffer"),
            .usage = memory_type.toGPUBufferUsage(),
            .size = buffer_size_bytes,
            .mapped_at_creation = @as(u32, @intFromBool(false)),
        }).?;
        errdefer buffer.release();

        return Self{
            .gpu = gpu,
            .buffer = buffer,
            .buffer_size = buffer_size_bytes,
            .memory_type = memory_type,
        };
    }

    pub fn deinit(self: *Self) void {
        self.buffer.release();
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
        _ = self.buffer.mapAsync(self.memory_type.toGPUMapMode(), 0, size_bytes, wgpu.BufferMapCallbackInfo{
            .callback = handleBufferMap,
            .userdata1 = @ptrCast(&buffer_map_complete),
        });

        slog.debug("Waiting for buffer map to complete", .{});

        // Wait for the GPU to finish working on the submitted work. This doesn't work on WebGPU, so we would need
        // to rely on the callback to know when the buffer is mapped.
        self.gpu.instance.processEvents();
        while (!buffer_map_complete) {
            self.gpu.instance.processEvents();
        }
        // _ = device.poll(true, null);

        slog.debug("Buffer map complete", .{});

        return self.buffer.getMappedRange(0, size_bytes).?;
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
        const upload_mapped_ptr: *anyopaque = self.mapUpload(size_bytes);
        const upload_buffer_ptr: [*]T = @ptrCast(@alignCast(upload_mapped_ptr));
        const upload_buffer_slice = upload_buffer_ptr[0..(roi.w * roi.h * format.nchannels())];
        defer self.unmapUpload();

        @memcpy(upload_buffer_slice, data);
    }

    // pub const BufferAllocator = std.heap.FixedBufferAllocator;
    pub const Allocator = zuballoc.SubAllocator;

    pub fn fixedBufferAllocator(self: *Self) !Allocator {
        // slog.debug("Buffer size: {d}", .{gpu_memory.buffer_size});
        const mapped_ptr: *anyopaque = self.mapSize(self.buffer_size);
        defer self.unmap();
        const buffer_ptr: [*]u8 = @ptrCast(@alignCast(mapped_ptr));
        const buffer_slice = buffer_ptr[0..@as(usize, self.buffer_size)];
        // const buf_allocator = std.heap.FixedBufferAllocator.init(buffer_slice);
        const buf_allocator = try zuballoc.SubAllocator.init(std.heap.smp_allocator, buffer_slice, 256);
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
        const data_size: usize = roi.w * roi.h * format.bpp();
        const offset = @as(u64, roi.y) * bytes_per_row + roi.x * format.bpp();
        const data_layout = wgpu.TexelCopyBufferLayout{
            .offset = offset,
            .bytes_per_row = bytes_per_row,
            .rows_per_image = roi.h,
        };

        const copy_size = wgpu.Extent3D{
            .width = roi.w,
            .height = roi.h,
            .depth_or_array_layers = 1,
        };
        const destination = wgpu.TexelCopyTextureInfo{
            .texture = texture.texture,
            .mip_level = 0,
            // .origin = wgpu.Origin3D{ .x = roi.x, .y = roi.y, .z = 0 },
            .origin = wgpu.Origin3D{ .x = 0, .y = 0, .z = 0 },
        };

        self.gpu.queue.writeTexture(
            destination,
            @ptrCast(data.ptr),
            data_size,
            data_layout,
            copy_size,
        );
    }
};

pub const Encoder = struct {
    encoder: *wgpu.CommandEncoder = undefined,
    const Self = @This();
    pub fn start(gpu: *GPU) !Self {
        // The command encoder allows us to record commands that we will later submit to the GPU.
        const encoder = gpu.device.createCommandEncoder(&wgpu.CommandEncoderDescriptor{
            .label = wgpu.StringView.fromSlice("Command Encoder"),
        }).?;
        errdefer encoder.release();

        return Self{
            .encoder = encoder,
        };
    }

    pub fn deinit(self: *Self) void {
        self.encoder.release();
    }

    /// you need to submit the command buffer to the GPU queue after finishing the encoder
    pub fn finish(self: *Self) ?*wgpu.CommandBuffer {
        slog.debug("Finishing command encoder", .{});

        // We finish the encoder, giving us a fully recorded command buffer.
        const command_buffer = self.encoder.finish(&wgpu.CommandBufferDescriptor{
            .label = wgpu.StringView.fromSlice("Command Buffer"),
        }).?;

        // the command buffer need to be released after submitting with command_buffer.release()
        // GPU.run() will do that for you
        return command_buffer;
    }

    pub fn enqueueShader(self: *Self, compute_pipeline: *const ComputePipeline, bindings: *Bindings, work_size: ROI) void {
        slog.debug("Enqueuing compute shader", .{});
        // A compute pass is a single series of compute operations. While we are recording a compute
        // pass, we cannot record to the encoder.
        const compute_pass = self.encoder.beginComputePass(&wgpu.ComputePassDescriptor{
            .label = wgpu.StringView.fromSlice("Compute Pass"),
        }).?;
        // Set the pipeline that we want to use
        compute_pass.setPipeline(compute_pipeline.pipeline);

        // compute_pass.setBindGroup(0, bindings.bind_group, 0, null);
        for (bindings.bind_groups, 0..) |bind_group, index| {
            const bg = bind_group orelse continue;
            slog.debug("Setting bind group {d}", .{index});
            compute_pass.setBindGroup(@intCast(index), bg, 0, null);
        }

        // Now we dispatch a series of workgroups. Each workgroup is a 3D grid of individual programs.
        //
        // If the user passes 32 inputs, we will
        // dispatch 1 workgroups. If the user passes 65 inputs, we will dispatch 2 workgroups, etc.
        const workgroup_count_x = (work_size.w + WORKGROUP_SIZE_X - 1) / WORKGROUP_SIZE_X; // ceil division
        const workgroup_count_y = (work_size.h + WORKGROUP_SIZE_Y - 1) / WORKGROUP_SIZE_Y; // ceil division
        const workgroup_count_z = 1;

        { // Debug info
            // const output_size = work_size.w * work_size.h;
            // const workgroup_size = WORKGROUP_SIZE_X * WORKGROUP_SIZE_Y * WORKGROUP_SIZE_Z;
            // slog.debug("output_size: {d}", .{output_size});
            // slog.debug("workgroup_size: {d}", .{workgroup_size});
            // slog.debug("workgroup_count_x: {d}", .{workgroup_count_x});
            // slog.debug("workgroup_count_y: {d}", .{workgroup_count_y});
            // slog.debug("workgroup_count_z: {d}", .{workgroup_count_z});
            // slog.debug("total workgroups: {d}", .{workgroup_count_x * workgroup_count_y * workgroup_count_z});
            // slog.debug("total invocations: {d}", .{@as(u32, workgroup_count_x) * workgroup_count_y * workgroup_count_z * workgroup_size});
        }

        slog.debug("Dispatching compute work", .{});
        compute_pass.dispatchWorkgroups(workgroup_count_x, workgroup_count_y, workgroup_count_z);
        // Now we drop the compute pass, giving us access to the encoder again.
        compute_pass.end();
    }

    pub fn enqueueBufToTex(self: *Self, memory: *Buffer, mem_offset: usize, texture: *Texture, roi: ROI) !void {
        slog.debug("Writing GPU buffer to Shader Buffer", .{});

        // check bytes_per_row is a multiple of 256
        const bytes_per_row = roi.w * texture.format.bpp();
        const padded_bytes_per_row = ((bytes_per_row + COPY_BYTES_PER_ROW_ALIGNMENT - 1) / COPY_BYTES_PER_ROW_ALIGNMENT) * COPY_BYTES_PER_ROW_ALIGNMENT; // ceil to next multiple of 256

        // We add a copy operation to the encoder. This will copy the data from the upload buffer on the
        // CPU to the input buffer on the GPU.
        const copy_size = wgpu.Extent3D{
            .width = roi.w,
            .height = roi.h,
            .depth_or_array_layers = 1,
        };
        const offset = @as(u64, mem_offset); //+ @as(u64, roi.y) * padded_bytes_per_row + roi.x * texture.format.bpp();
        const source = wgpu.TexelCopyBufferInfo{
            .buffer = memory.buffer,
            .layout = wgpu.TexelCopyBufferLayout{
                .offset = offset,
                .bytes_per_row = padded_bytes_per_row,
                .rows_per_image = roi.h,
            },
        };
        const destination = wgpu.TexelCopyTextureInfo{
            .texture = texture.texture,
            .mip_level = 0,
            // .origin = wgpu.Origin3D{ .x = roi.x, .y = roi.y, .z = 0 },
            .origin = wgpu.Origin3D{ .x = 0, .y = 0, .z = 0 },
        };
        self.encoder.copyBufferToTexture(&source, &destination, &copy_size);
    }
    pub fn enqueueTexToBuf(self: *Self, buffer: *Buffer, mem_offset: usize, texture: *Texture, roi: ROI) !void {
        slog.debug("Reading GPU buffer from Shader Buffer", .{});

        // check bytes_per_row is a multiple of 256
        const bytes_per_row = roi.w * texture.format.bpp();
        // if (bytes_per_row % 256 != 0) {
        //     slog.err("bytes_per_row must be a multiple of 256, got {d}", .{bytes_per_row});
        //     return error.InvalidInput;
        // }
        const padded_bytes_per_row = ((bytes_per_row + COPY_BYTES_PER_ROW_ALIGNMENT - 1) / COPY_BYTES_PER_ROW_ALIGNMENT) * COPY_BYTES_PER_ROW_ALIGNMENT; // ceil to next multiple of 256

        // We add a copy operation to the encoder. This will copy the data from the output buffer on the
        // GPU to the download buffer on the CPU.
        // self.encoder.copyBufferToBuffer(self.buffer[self.dst_index], 0, self.download_buffer, 0, self.buffer[self.dst_index].getSize());
        // const copy_size = self.textures[self.dst_index].getWidth() * self.textures[self.dst_index].getHeight() * 4; // width * height * RGBA
        const copy_size = wgpu.Extent3D{
            .width = roi.w,
            .height = roi.h,
            .depth_or_array_layers = 1,
        };
        const source = wgpu.TexelCopyTextureInfo{
            .texture = texture.texture,
            .mip_level = 0,
            // .origin = wgpu.Origin3D{ .x = roi.x, .y = roi.y, .z = 0 },
            .origin = wgpu.Origin3D{ .x = 0, .y = 0, .z = 0 },
        };
        const offset = @as(u64, mem_offset); //+ @as(u64, roi.y) * padded_bytes_per_row + roi.x * texture.format.bpp();
        const destination = wgpu.TexelCopyBufferInfo{
            .buffer = buffer.buffer,
            .layout = wgpu.TexelCopyBufferLayout{
                .offset = offset,
                .bytes_per_row = padded_bytes_per_row,
                .rows_per_image = roi.h,
            },
        };
        self.encoder.copyTextureToBuffer(&source, &destination, &copy_size);
    }

    pub fn enqueueTexToTex(self: *Self, src_texture: *Texture, dst_texture: *Texture, roi: ROI) !void {
        slog.debug("Copying GPU texture to another GPU texture", .{});

        const copy_size = wgpu.Extent3D{
            .width = roi.w,
            .height = roi.h,
            .depth_or_array_layers = 1,
        };
        const source = wgpu.TexelCopyTextureInfo{
            .texture = src_texture.texture,
            .mip_level = 0,
            // .origin = wgpu.Origin3D{ .x = roi.x, .y = roi.y, .z = 0 },
            .origin = wgpu.Origin3D{ .x = 0, .y = 0, .z = 0 },
        };

        const destination = wgpu.TexelCopyTextureInfo{
            .texture = dst_texture.texture,
            .mip_level = 0,
            // .origin = wgpu.Origin3D{ .x = roi.x, .y = roi.y, .z = 0 },
            .origin = wgpu.Origin3D{ .x = 0, .y = 0, .z = 0 },
        };

        self.encoder.copyTextureToTexture(&source, &destination, &copy_size);
    }
    pub fn enqueueBufToBuf(self: *Self, src_memory: *Buffer, src_offset: usize, dst_memory: *Buffer, dst_offset: usize, size_bytes: usize) !void {
        slog.debug("Copying GPU buffer to another GPU buffer", .{});

        const src_offset_aligned = @as(u64, src_offset);
        const dst_offset_aligned = @as(u64, dst_offset);
        const size_bytes_aligned = @as(u64, size_bytes);

        self.encoder.copyBufferToBuffer(
            src_memory.buffer,
            src_offset_aligned,
            dst_memory.buffer,
            dst_offset_aligned,
            size_bytes_aligned,
        );
    }
};

pub const TextureFormat = enum {
    rgba16float,
    rgba16uint,
    r8uint,
    r16uint,
    r16float,

    // special cases
    rggb16float, // we will treat this as rgba16float with quarter width
    rggb16uint,

    pub fn toWGPUFormat(self: TextureFormat) wgpu.TextureFormat {
        return switch (self) {
            .rgba16float => wgpu.TextureFormat.rgba16_float,
            .rgba16uint => wgpu.TextureFormat.rgba16_uint,
            .r8uint => wgpu.TextureFormat.r8_uint,
            .r16uint => wgpu.TextureFormat.r16_uint,
            .r16float => wgpu.TextureFormat.r16_float,

            // special cases
            .rggb16float => wgpu.TextureFormat.rgba16_float,
            .rggb16uint => wgpu.TextureFormat.rgba16_uint,
        };
    }

    pub fn toWGPUSampleType(self: TextureFormat) wgpu.SampleType {
        return switch (self) {
            .rgba16float => wgpu.SampleType.float,
            .rgba16uint => wgpu.SampleType.u_int,
            .r8uint => wgpu.SampleType.u_int,
            .r16uint => wgpu.SampleType.u_int,
            .r16float => wgpu.SampleType.float,

            // special cases
            .rggb16float => wgpu.SampleType.float,
            .rggb16uint => wgpu.SampleType.u_int,
        };
    }

    // TODO: make to following functions comptime accessible

    /// bytes per pixel
    pub fn bpp(self: TextureFormat) u32 {
        return self.nchannels() * self.baseTypeSize();
    }

    /// number of channels
    pub fn nchannels(self: TextureFormat) u32 {
        return switch (self) {
            .rgba16float => 4,
            .rgba16uint => 4,
            .r8uint => 1,
            .r16uint => 1,
            .r16float => 1,

            // special cases
            .rggb16float => 4,
            .rggb16uint => 4,
        };
    }

    pub fn baseTypeSize(self: TextureFormat) u32 {
        return switch (self) {
            .rgba16float => @sizeOf(f16),
            .rgba16uint => @sizeOf(u16),
            .r8uint => @sizeOf(u8),
            .r16uint => @sizeOf(u16),
            .r16float => @sizeOf(f16),

            // special cases
            .rggb16float => @sizeOf(f16),
            .rggb16uint => @sizeOf(u16),
        };
    }
};

pub const Texture = struct {
    texture: *wgpu.Texture,
    format: TextureFormat,
    roi: ROI,
    // name: []const u8,

    const Self = @This();

    pub fn init(gpu: *GPU, name: []const u8, format: TextureFormat, roi: ROI) !Self {
        slog.debug("Creating texture {s} of size {d}x{d}", .{ @tagName(format), roi.w, roi.h });
        var limits = wgpu.Limits{};
        _ = gpu.adapter.getLimits(&limits);

        var usage = wgpu.TextureUsages.storage_binding | wgpu.TextureUsages.texture_binding | wgpu.TextureUsages.copy_src | wgpu.TextureUsages.copy_dst;
        // r16uint does not support storage binding
        if (format == .r16uint or format == .r16float) {
            usage = wgpu.TextureUsages.texture_binding | wgpu.TextureUsages.copy_src | wgpu.TextureUsages.copy_dst;
        }

        const texture = gpu.device.createTexture(&wgpu.TextureDescriptor{
            .label = wgpu.StringView.fromSlice(name),
            .size = wgpu.Extent3D{
                .width = roi.w,
                .height = roi.h,
                .depth_or_array_layers = 1,
            },
            .mip_level_count = 1,
            .sample_count = 1,
            .dimension = wgpu.TextureDimension.@"2d",
            .format = format.toWGPUFormat(),
            .usage = usage,
        }).?;
        errdefer texture.release();
        return Texture{
            .texture = texture,
            .format = format,
            .roi = roi,
            // .name = name,
        };
    }

    pub fn deinit(self: *Self) void {
        self.texture.release();
    }
};

// pub const BindGroupEntryType = enum {
//     buffer,
//     texture,
// };

pub const BindGroupEntry = struct {
    texture: ?Texture = null,
    buffer: ?Buffer = null,
};

/// The Bindings (bind group) contains the actual resources to bind to the pipeline.
/// Similar to vulkan's descriptor sets, a Bindings struct holds the actual resources
/// (buffers, textures, etc) that are bound to a shader pipeline.
pub const Bindings = struct {
    bind_groups: [MAX_BIND_GROUPS]?*wgpu.BindGroup,
    const Self = @This();

    pub fn init(
        gpu: *GPU,
        compute_pipeline: *const ComputePipeline,
        bind_group_entries: [MAX_BIND_GROUPS]?[MAX_BINDINGS]?BindGroupEntry,
    ) !Self {
        slog.debug("Creating Bindings", .{});
        var limits = wgpu.Limits{};
        _ = gpu.adapter.getLimits(&limits);

        // Even when the buffers are individually dropped, wgpu will keep the bind group and buffers
        // alive until the bind group itself is dropped.
        var bind_groups: [MAX_BIND_GROUPS]?*wgpu.BindGroup = @splat(null);
        for (bind_group_entries, 0..) |bind_group, bind_group_number| {
            var wgpu_bind_group_entries: [MAX_BINDINGS]wgpu.BindGroupEntry = undefined;
            const bg = bind_group orelse continue;
            var bind_count: u32 = 0;
            for (bg, 0..) |bind_group_entry, bind_group_entry_number| {
                const bge = bind_group_entry orelse continue;
                if (bge.texture) |texture| {
                    const entry = wgpu.BindGroupEntry{
                        .binding = @intCast(bind_group_entry_number),
                        .texture_view = texture.texture.createView(null),
                    };
                    wgpu_bind_group_entries[bind_group_entry_number] = entry;
                } else if (bge.buffer) |buffer| {
                    if (buffer.buffer_size == 0) {
                        slog.err("Buffer size is 0, cannot bind bind group {d} entry {d} to pipeline", .{ bind_group_number, bind_group_entry_number });
                        return error.InvalidInput;
                    }
                    const entry = wgpu.BindGroupEntry{
                        .binding = @intCast(bind_group_entry_number),
                        .buffer = buffer.buffer,
                        .offset = 0,
                        .size = buffer.buffer_size,
                    };
                    wgpu_bind_group_entries[bind_group_entry_number] = entry;
                }
                bind_count += 1;
            }
            const wgpu_bind_group = gpu.device.createBindGroup(&wgpu.BindGroupDescriptor{
                .label = wgpu.StringView.fromSlice("Bind Group"),
                .layout = compute_pipeline.wgpu_bind_group_layouts[bind_group_number].?,
                .entry_count = bind_count,
                .entries = &wgpu_bind_group_entries,
            }).?;
            errdefer wgpu_bind_group.release();
            bind_groups[bind_group_number] = wgpu_bind_group;
        }
        return Bindings{
            .bind_groups = bind_groups,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.bind_groups) |bind_group| {
            var bg = bind_group orelse continue;
            bg.release();
        }
    }
};

pub const BindGroupLayoutEntryAccess = enum {
    read,
    write,
};

pub const BindGroupLayoutTextureEntry = struct {
    format: TextureFormat,
    access: BindGroupLayoutEntryAccess,
};

pub const BindGroupLayoutBufferEntryType = enum {
    storage,
    uniform,
    // read_only_storage,

    pub fn toWGPUBufferBindingType(self: BindGroupLayoutBufferEntryType) wgpu.BufferBindingType {
        return switch (self) {
            .storage => wgpu.BufferBindingType.storage,
            .uniform => wgpu.BufferBindingType.uniform,
            // .read_only_storage => wgpu.BufferBindingType.read_only_storage,
        };
    }
};

pub const BindGroupLayoutBufferEntry = struct {
    // size: u64,
    binding_type: BindGroupLayoutBufferEntryType,
};

pub const BindGroupLayoutEntry = struct {
    texture: ?BindGroupLayoutTextureEntry = null,
    buffer: ?BindGroupLayoutBufferEntry = null,
};

// pub const Shader = wgpu.ShaderModule;

pub const ShaderLanguage = enum {
    wgsl,
    // spirv,
    glsl,
};

pub const CompileShaderOpts = struct {
    name: []const u8 = "Compute Shader",
    type: ShaderLanguage = .wgsl,
};

pub const Shader = struct {
    shader_module: *wgpu.ShaderModule,

    const Self = @This();

    pub fn compile(
        gpu: *GPU,
        shader_source: []const u8,
        opts: CompileShaderOpts,
    ) !Shader {
        slog.info("Compiling shader {s}", .{opts.name});

        const descriptor = switch (opts.type) {
            .wgsl => wgpu.shaderModuleWGSLDescriptor(.{
                .label = opts.name,
                .code = shader_source,
            }),
            // .spirv => wgpu.shaderModuleSPIRVDescriptor(.{
            //     .label = opts.name,
            //     .code = shader_source,
            //     .code_size = @as(usize, shader_source.len) / @sizeOf(u32), // need to test
            // }),
            .glsl => wgpu.shaderModuleGLSLDescriptor(.{
                .label = opts.name,
                .code = shader_source,
                .stage = @as(wgpu.ShaderStage, 0x0000000000000004), //wgpu.ShaderStage.compute, // needed for GLSL
            }),
        };

        const shader_module = gpu.device.createShaderModule(&descriptor).?;

        return Self{
            .shader_module = shader_module,
        };
    }

    pub fn deinit(self: *Self) void {
        self.shader_module.release();
    }
};

pub const ComputePipeline = struct {
    name: []const u8,
    wgpu_bind_group_layouts: [MAX_BIND_GROUPS]?*wgpu.BindGroupLayout,
    pipeline_layout: *wgpu.PipelineLayout,
    // shader_module: *wgpu.ShaderModule,
    // shader: *Shader,
    pipeline: *wgpu.ComputePipeline,

    const Self = @This();

    pub fn init(
        gpu: *GPU,
        // shader_source: []const u8,
        shader: Shader,
        name: []const u8,
        bind_group_layout_entries: [MAX_BIND_GROUPS]?[MAX_BINDINGS]?BindGroupLayoutEntry,
    ) !Self {
        slog.debug("Initializing ComputePipeline for {s}", .{name});
        // std.debug.print("Compiling shader for {s}\n", .{name});

        // A bind group layout describes the types of resources that a bind group can contain. Think
        // of this like a C-style header declaration, ensuring both the pipeline and bind group agree
        // on the types of resources.
        //
        // Note, we are using a texture in binding 0 and a storage texture in binding 1.
        // this is because readable storage textures are not supported in WebGPU unless you enable
        // (readonly_and_readwrite_storage_textures). This is also done in vkdt.
        //
        // First, we are going to create the bind group layout for group 0
        // this will hold the input/output textures

        var wgpu_bind_group_layouts: [MAX_BIND_GROUPS]?*wgpu.BindGroupLayout = @splat(null);

        var bind_group_layout_count: u32 = 0;
        bgle_blk: for (bind_group_layout_entries, 0..) |bind_group_layout, bind_group_layout_number| {
            const bgl = bind_group_layout orelse break :bgle_blk;
            var wgpu_g0_bind_group_layout_entries: [MAX_BINDINGS]wgpu.BindGroupLayoutEntry = undefined;

            var bind_count: u32 = 0;
            bgl_blk: for (bgl, 0..) |bind_group_layout_entry, bind_number| {
                const bgle = bind_group_layout_entry orelse break :bgl_blk;

                if (bgle.texture) |bgle_texture| {
                    switch (bgle_texture.access) {
                        .read => {
                            // Note: we don't need format for input textures
                            // but we do need to specify the sample type
                            const entry = wgpu.BindGroupLayoutEntry{
                                .binding = @intCast(bind_number),
                                .visibility = wgpu.ShaderStages.compute,
                                .texture = wgpu.TextureBindingLayout{
                                    .view_dimension = wgpu.ViewDimension.@"2d",
                                    .sample_type = bgle_texture.format.toWGPUSampleType(),
                                },
                            };
                            wgpu_g0_bind_group_layout_entries[bind_number] = entry;
                        },
                        .write => {
                            const entry = wgpu.BindGroupLayoutEntry{
                                .binding = @intCast(bind_number),
                                .visibility = wgpu.ShaderStages.compute,
                                .storage_texture = wgpu.StorageTextureBindingLayout{
                                    .access = wgpu.StorageTextureAccess.write_only,
                                    .format = bgle_texture.format.toWGPUFormat(),
                                    .view_dimension = wgpu.ViewDimension.@"2d",
                                },
                            };
                            wgpu_g0_bind_group_layout_entries[bind_number] = entry;
                        },
                    }
                } else if (bgle.buffer) |bgle_buffer| {
                    const entry = wgpu.BindGroupLayoutEntry{
                        .binding = @intCast(bind_number),
                        .visibility = wgpu.ShaderStages.compute,
                        .buffer = wgpu.BufferBindingLayout{
                            // .type = wgpu.BufferBindingType.storage,
                            .type = bgle_buffer.binding_type.toWGPUBufferBindingType(),

                            // .has_dynamic_offset = @intFromBool(false),
                            // .min_binding_size = bge_buffer.size,
                        },
                    };
                    wgpu_g0_bind_group_layout_entries[bind_number] = entry;
                }
                bind_count += 1;
            }
            const wgpu_bind_group_layout = gpu.device.createBindGroupLayout(&wgpu.BindGroupLayoutDescriptor{
                // .label = wgpu.StringView.fromSlice("Bind Group Layout for " ++ name),
                .label = wgpu.StringView.fromSlice("Bind Group Layout"),
                .entry_count = bind_count,
                .entries = &wgpu_g0_bind_group_layout_entries,
            }).?;
            errdefer wgpu_bind_group_layout.release();

            wgpu_bind_group_layouts[bind_group_layout_number] = wgpu_bind_group_layout;
            bind_group_layout_count += 1;
        }

        // this basically converts from [MAX_BIND_GROUPS]?*wgpu.BindGroupLayout to [MAX_BIND_GROUPS]*wgpu.BindGroupLayout
        // by skipping null entries
        var bind_group_layouts: [MAX_BIND_GROUPS]*wgpu.BindGroupLayout = undefined;
        for (wgpu_bind_group_layouts, 0..) |bgl, index| {
            const layout = bgl orelse continue;
            bind_group_layouts[index] = layout;
        }
        // The pipeline layout describes the bind groups that a pipeline expects
        const wgpu_pipeline_layout = gpu.device.createPipelineLayout(&wgpu.PipelineLayoutDescriptor{
            // .label = wgpu.StringView.fromSlice("Pipeline Layout for " ++ name),
            .label = wgpu.StringView.fromSlice("Pipeline Layout"),
            .bind_group_layout_count = bind_group_layout_count,
            .bind_group_layouts = &bind_group_layouts,
        }).?;
        errdefer wgpu_pipeline_layout.release();

        // The pipeline is the ready-to-go program state for the GPU. It contains the shader modules,
        // the interfaces (bind group layouts) and the shader entry point.
        // this does some compilation/validation/linking as well
        const pipeline = gpu.device.createComputePipeline(&wgpu.ComputePipelineDescriptor{
            .label = wgpu.StringView.fromSlice("Compute Pipeline"),
            .layout = wgpu_pipeline_layout,
            .compute = wgpu.ProgrammableStageDescriptor{
                .module = shader.shader_module,
                .entry_point = wgpu.StringView.fromSlice(name),
            },
        }).?;
        errdefer pipeline.release();

        return ComputePipeline{
            .name = name,
            .wgpu_bind_group_layouts = wgpu_bind_group_layouts,
            // .shader_module = shader_module,
            // .shader = shader,
            .pipeline_layout = wgpu_pipeline_layout,
            .pipeline = pipeline,
        };
    }

    pub fn deinit(self: *Self) void {
        slog.debug("De-initializing ShaderPass {s}", .{self.name});

        for (self.wgpu_bind_group_layouts) |bind_group_layout| {
            var bgl = bind_group_layout orelse continue;
            bgl.release();
        }

        // self.shader_module.release();
        self.pipeline_layout.release();
        self.pipeline.release();
    }
};

/// GPU manages the WebGPU instance, adapter, device, and queue.
pub const GPU = struct {
    instance: *wgpu.Instance = undefined,
    adapter: *wgpu.Adapter = undefined,
    device: *wgpu.Device = undefined,
    queue: *wgpu.Queue = undefined,
    adapter_name: []const u8 = "",

    const Self = @This();

    pub fn init() !Self {
        slog.debug("Initializing GPU", .{});

        const instance = wgpu.Instance.create(null).?;
        errdefer instance.release();

        const adapter_request = instance.requestAdapterSync(&wgpu.RequestAdapterOptions{
            .power_preference = .high_performance,
        }, 0);
        const adapter = switch (adapter_request.status) {
            .success => adapter_request.adapter.?,
            else => return error.NoAdapter,
        };
        errdefer adapter.release();

        var info: wgpu.AdapterInfo = undefined;
        const status = adapter.getInfo(&info);
        if (status != .success) {
            slog.err("Failed to get adapter info", .{});
            return error.AdapterInfo;
        } else {
            const name = info.device.toSlice();
            if (name) |value| {
                slog.info("Using adapter: {s} (backend={s}, type={s})", .{ value, @tagName(info.backend_type), @tagName(info.adapter_type) });
            } else {
                slog.err("Failed to get adapter name", .{});
            }
        }

        // We then create a `Device` and a `Queue` from the `Adapter`.
        // https://webgpureport.org/
        const required_features = [_]wgpu.FeatureName{
            .shader_f16, // enable f16 support
            .texture_adapter_specific_format_features, // without this flag, read/write storage access is not allowed at all.
            // .mappable_primary_buffers, // https://docs.rs/wgpu-types/0.7.0/wgpu_types/struct.Features.html#associatedconstant.MAPPABLE_PRIMARY_BUFFERS
        };
        const required_limits = wgpu.Limits{
            // .max_bind_groups = 8,
            // .max_bindings_per_bind_group = 16,
            // .max_texture_dimension_2d = 16384,
            .max_storage_buffer_binding_size = 1024 * 1024 * 1024, // 1 GB
            .max_buffer_size = 1024 * 1024 * 1024, // 1 GB
        };
        const device_descriptor = wgpu.DeviceDescriptor{
            .required_limits = &required_limits,
            .required_features = &required_features,
        };
        const device_request = adapter.requestDeviceSync(
            instance,
            &device_descriptor,
            0,
        );
        const device = switch (device_request.status) {
            .success => device_request.device.?,
            else => return error.NoDevice,
        };
        errdefer device.release();

        const queue = device.getQueue() orelse return error.NoQueue;
        errdefer queue.release();

        var limits = wgpu.Limits{};
        _ = adapter.getLimits(&limits);

        slog.info("Adapter limits:", .{});
        slog.info(" max_bind_groups: {d}", .{limits.max_bind_groups});
        slog.info(" max_bindings_per_bind_group: {d}", .{limits.max_bindings_per_bind_group});
        // slog.info(" max_texture_dimension_1d: {d}", .{limits.max_texture_dimension_1d});
        slog.info(" max_texture_dimension_2d: {d}", .{limits.max_texture_dimension_2d});
        // slog.info(" max_texture_dimension_3d: {d}", .{limits.max_texture_dimension_3d});
        // slog.info(" max_texture_array_layers: {d}", .{limits.max_texture_array_layers});
        slog.info(" max_compute_invocations_per_workgroup: {d}", .{limits.max_compute_invocations_per_workgroup});
        slog.info(" max_compute_workgroup_size_x: {d}", .{limits.max_compute_workgroup_size_x});
        slog.info(" max_compute_workgroup_size_y: {d}", .{limits.max_compute_workgroup_size_y});
        slog.info(" max_compute_workgroup_size_z: {d}", .{limits.max_compute_workgroup_size_z});
        slog.info(" max_compute_workgroups_per_dimension: {d}", .{limits.max_compute_workgroups_per_dimension});
        slog.info(" max_buffer_size: {B:.2}", .{limits.max_buffer_size});
        slog.info(" max_uniform_buffer_binding_size: {B:.2}", .{limits.max_uniform_buffer_binding_size});
        slog.info(" max_storage_buffer_binding_size: {B:.2}", .{limits.max_storage_buffer_binding_size});
        slog.info(" min_uniform_buffer_offset_alignment: {d}", .{limits.min_uniform_buffer_offset_alignment});
        slog.info(" min_storage_buffer_offset_alignment: {d}", .{limits.min_storage_buffer_offset_alignment});

        return Self{
            .instance = instance,
            .adapter = adapter,
            .device = device,
            .queue = queue,
            .adapter_name = info.device.toSlice() orelse "Unknown",
        };
    }

    pub fn deinit(self: *Self) void {
        slog.debug("De-initializing GPU", .{});

        self.queue.release();
        self.device.release();
        self.adapter.release();
        self.instance.release();
    }

    pub fn run(self: *Self, command_buffer: ?*wgpu.CommandBuffer) !void {
        slog.debug("Submitting command buffer to GPU", .{});

        const command_buffer_unwrapped = command_buffer orelse {
            slog.err("No command buffer provided to GPU.run", .{});
            return error.InvalidCommandBuffer;
        };

        // At this point nothing has actually been executed on the gpu. We have recorded a series of
        // commands that we want to execute, but they haven't been sent to the gpu yet.
        //
        // Submitting to the queue sends the command buffer to the gpu. The gpu will then execute the
        // commands in the command buffer in order.
        self.queue.submit(&[_]*const wgpu.CommandBuffer{command_buffer_unwrapped});
        command_buffer_unwrapped.release();
    }
};
