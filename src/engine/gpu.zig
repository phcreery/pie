//! A lot of this is just a wrapper around wgpu to make it easier to use in the context of image processing.
//! intended to be used with [shahwali/wgpu-zig](https://codeberg.org/shahwali/wgpu-zig) (wgpu-native)

const std = @import("std");
const wgpu = @import("wgpu_zig");
const gpu_data = @import("gpu_data.zig");
const ROI = @import("ROI.zig");
const zuballoc = @import("zuballoc");

const c = wgpu.c;

const slog = std.log.scoped(.gpu);

// Copy error Buffer offset 4 is not aligned to block size or `COPY_BUFFER_ALIGNMENT`
// https://github.com/gfx-rs/wgpu/blob/trunk/wgpu-types/src/lib.rs#L96
pub const COPY_BUFFER_ALIGNMENT: std.mem.Alignment = .@"8";
pub const COPY_BYTES_PER_ROW_ALIGNMENT: u32 = 256; // wgpu.COPY_BYTES_PER_ROW_ALIGNMENT

pub const MAX_BIND_GROUPS: usize = 4;
pub const MAX_BINDINGS: usize = 8;

// Workgroup size must match the compute shader
pub const WORKGROUP_SIZE_X: u32 = 8;
pub const WORKGROUP_SIZE_Y: u32 = 8;
pub const WORKGROUP_SIZE_Z: u32 = 1;

pub const layoutStruct = gpu_data.layoutStruct;

fn handleBufferMap(status: c.WGPUMapAsyncStatus, _: c.WGPUStringView, userdata1: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
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

    pub fn toGPUBufferUsage(self: MemoryType) wgpu.Buffer.Usage {
        return switch (self) {
            .upload => .{ .copy_src = true, .map_write = true },
            .download => .{ .copy_dst = true, .map_read = true },
            .storage => .{ .copy_dst = true, .storage = true },
            .uniform => .{ .copy_dst = true, .uniform = true },
        };
    }

    fn toGPUMapMode(self: MemoryType) c_uint {
        return switch (self) {
            .upload => c.WGPUMapMode_Write,
            .download => c.WGPUMapMode_Read,
            .storage => c.WGPUMapMode_Write,
            .uniform => c.WGPUMapMode_Write,
        };
    }
};

/// GPU allocator using an upload and download buffer for staging data to/from the GPU.
/// GPU must outlive Buffer
pub const Buffer = struct {
    gpu: *GPU,
    buffer: wgpu.Buffer,
    buffer_size: u64,
    memory_type: MemoryType,

    const Self = @This();

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
};

pub const Encoder = struct {
    encoder: wgpu.CommandEncoder = undefined,
    const Self = @This();
    pub fn start(gpu: *GPU) !Self {
        // The command encoder allows us to record commands that we will later submit to the GPU.
        const encoder = try gpu.device.createCommandEncoder(.{
            .label = "Command Encoder",
        });
        errdefer encoder.deinit();

        return Self{
            .encoder = encoder,
        };
    }

    pub fn deinit(self: *Self) void {
        self.encoder.deinit();
    }

    /// you need to submit the command buffer to the GPU queue after finishing the encoder
    pub fn finish(self: *Self) ?wgpu.CommandEncoder.CommandBuffer {
        slog.debug("Finishing command encoder", .{});

        // We finish the encoder, giving us a fully recorded command buffer.
        // the command buffer needs to be released after submitting
        // GPU.run() will do that for you
        return self.encoder.finish(.{
            .label = "Command Buffer",
        }) catch null;
    }

    pub fn enqueueShader(self: *Self, compute_pipeline: *const ComputePipeline, bindings: *Bindings, work_size: ROI) void {
        slog.debug("Enqueuing compute shader", .{});
        // A compute pass is a single series of compute operations. While we are recording a compute
        // pass, we cannot record to the encoder.
        var compute_pass = self.encoder.beginComputePass(.{
            .label = "Compute Pass",
        }) catch unreachable;
        defer compute_pass.deinit();

        // Set the pipeline that we want to use
        compute_pass.setPipeline(compute_pipeline.pipeline);

        for (bindings.bind_groups, 0..) |bind_group, index| {
            const bg = bind_group orelse continue;
            slog.debug("Setting bind group {d}", .{index});
            compute_pass.setBindGroup(@intCast(index), bg, &.{});
        }

        // Now we dispatch a series of workgroups. Each workgroup is a 3D grid of individual programs.
        //
        // If the user passes 32 inputs, we will
        // dispatch 1 workgroups. If the user passes 65 inputs, we will dispatch 2 workgroups, etc.
        const workgroup_count_x = (work_size.w + WORKGROUP_SIZE_X - 1) / WORKGROUP_SIZE_X; // ceil division
        const workgroup_count_y = (work_size.h + WORKGROUP_SIZE_Y - 1) / WORKGROUP_SIZE_Y; // ceil division
        const workgroup_count_z = 1;

        slog.debug("Dispatching compute work", .{});
        compute_pass.dispatchWorkgroups(workgroup_count_x, workgroup_count_y, workgroup_count_z);
        // Now we drop the compute pass, giving us access to the encoder again.
        compute_pass.end();
    }

    pub fn enqueueBufToTex(self: *Self, memory: *Buffer, mem_offset: usize, texture: *Texture, roi: ROI) !void {
        slog.debug("Writing GPU buffer to Shader Buffer", .{});

        const bytes_per_row = roi.w * texture.format.bpp();
        const padded_bytes_per_row = ((bytes_per_row + COPY_BYTES_PER_ROW_ALIGNMENT - 1) / COPY_BYTES_PER_ROW_ALIGNMENT) * COPY_BYTES_PER_ROW_ALIGNMENT; // ceil to next multiple of COPY_BYTES_PER_ROW_ALIGNMENT

        // We add a copy operation to the encoder. This will copy the data from the upload buffer on the
        // CPU to the input buffer on the GPU.
        const copy_size = c.WGPUExtent3D{
            .width = roi.w,
            .height = roi.h,
            .depthOrArrayLayers = 1,
        };
        const source = c.WGPUTexelCopyBufferInfo{
            .buffer = memory.buffer.buffer,
            .layout = .{
                .offset = @as(u64, mem_offset), //+ @as(u64, roi.y) * padded_bytes_per_row + roi.x * texture.format.bpp();
                .bytesPerRow = padded_bytes_per_row,
                .rowsPerImage = roi.h,
            },
        };
        const destination = c.WGPUTexelCopyTextureInfo{
            .texture = texture.texture.texture,
            .mipLevel = 0,
            .origin = .{ .x = 0, .y = 0, .z = 0 },
            .aspect = c.WGPUTextureAspect_All,
        };
        c.wgpuCommandEncoderCopyBufferToTexture(self.encoder.encoder, &source, &destination, &copy_size);
    }
    pub fn enqueueTexToBuf(self: *Self, buffer: *Buffer, mem_offset: usize, texture: *Texture, roi: ROI) !void {
        slog.debug("Reading GPU buffer from Shader Buffer", .{});

        const bytes_per_row = roi.w * texture.format.bpp();
        const padded_bytes_per_row = ((bytes_per_row + COPY_BYTES_PER_ROW_ALIGNMENT - 1) / COPY_BYTES_PER_ROW_ALIGNMENT) * COPY_BYTES_PER_ROW_ALIGNMENT; // ceil to next multiple of COPY_BYTES_PER_ROW_ALIGNMENT

        const copy_size = c.WGPUExtent3D{
            .width = roi.w,
            .height = roi.h,
            .depthOrArrayLayers = 1,
        };
        const source = c.WGPUTexelCopyTextureInfo{
            .texture = texture.texture.texture,
            .mipLevel = 0,
            .origin = .{ .x = 0, .y = 0, .z = 0 },
            .aspect = c.WGPUTextureAspect_All,
        };
        const destination = c.WGPUTexelCopyBufferInfo{
            .buffer = buffer.buffer.buffer,
            .layout = .{
                .offset = @as(u64, mem_offset), //+ @as(u64, roi.y) * padded_bytes_per_row + roi.x * texture.format.bpp();
                .bytesPerRow = padded_bytes_per_row,
                .rowsPerImage = roi.h,
            },
        };
        c.wgpuCommandEncoderCopyTextureToBuffer(self.encoder.encoder, &source, &destination, &copy_size);
    }

    pub fn enqueueTexToTex(self: *Self, src_texture: *Texture, dst_texture: *Texture, roi: ROI) !void {
        slog.debug("Copying GPU texture to another GPU texture", .{});

        const copy_size = c.WGPUExtent3D{
            .width = roi.w,
            .height = roi.h,
            .depthOrArrayLayers = 1,
        };
        const source = c.WGPUTexelCopyTextureInfo{
            .texture = src_texture.texture.texture,
            .mipLevel = 0,
            .origin = .{ .x = 0, .y = 0, .z = 0 },
            .aspect = c.WGPUTextureAspect_All,
        };
        const destination = c.WGPUTexelCopyTextureInfo{
            .texture = dst_texture.texture.texture,
            .mipLevel = 0,
            .origin = .{ .x = 0, .y = 0, .z = 0 },
            .aspect = c.WGPUTextureAspect_All,
        };
        c.wgpuCommandEncoderCopyTextureToTexture(self.encoder.encoder, &source, &destination, &copy_size);
    }
    pub fn enqueueBufToBuf(self: *Self, src_memory: *Buffer, src_offset: usize, dst_memory: *Buffer, dst_offset: usize, size_bytes: usize) !void {
        slog.debug("Copying GPU buffer to another GPU buffer", .{});

        self.encoder.copyBufferToBuffer(
            src_memory.buffer,
            @as(u64, src_offset),
            dst_memory.buffer,
            @as(u64, dst_offset),
            @as(u64, size_bytes),
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

    pub fn toWGPUFormat(self: TextureFormat) wgpu.Texture.Format {
        return switch (self) {
            .rgba16float => .rgba16_float,
            .rgba16uint => .rgba16_uint,
            .r8uint => .r8_uint,
            .r16uint => .r16_uint,
            .r16float => .r16_float,

            // special cases
            .rggb16float => .rgba16_float,
            .rggb16uint => .rgba16_uint,
        };
    }

    pub fn toWGPUSampleType(self: TextureFormat) wgpu.BindGroupLayout.TextureSampleType {
        return switch (self) {
            .rgba16float => .float,
            .rgba16uint => .uint,
            .r8uint => .uint,
            .r16uint => .uint,
            .r16float => .float,

            // special cases
            .rggb16float => .float,
            .rggb16uint => .uint,
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
    texture: wgpu.Texture,
    format: TextureFormat,
    roi: ROI,

    const Self = @This();

    pub fn init(gpu: *GPU, name: []const u8, format: TextureFormat, roi: ROI) !Self {
        slog.debug("Creating texture {s} of size {d}x{d}", .{ @tagName(format), roi.w, roi.h });

        var usage: wgpu.Texture.Usage = .{
            .storage_binding = true,
            .texture_binding = true,
            .copy_src = true,
            .copy_dst = true,
        };
        // r16uint does not support storage binding
        if (format == .r16uint or format == .r16float) {
            usage = .{
                .texture_binding = true,
                .copy_src = true,
                .copy_dst = true,
            };
        }

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
        return Texture{
            .texture = texture,
            .format = format,
            .roi = roi,
        };
    }

    pub fn deinit(self: *Self) void {
        self.texture.deinit();
    }
};

pub const BindGroupEntry = struct {
    texture: ?Texture = null,
    buffer: ?Buffer = null,
};

/// The Bindings (bind group) contains the actual resources to bind to the pipeline.
/// Similar to vulkan's descriptor sets, a Bindings struct holds the actual resources
/// (buffers, textures, etc) that are bound to a shader pipeline.
pub const Bindings = struct {
    bind_groups: [MAX_BIND_GROUPS]?wgpu.BindGroup,
    const Self = @This();

    pub fn init(
        gpu: *GPU,
        compute_pipeline: *const ComputePipeline,
        bind_group_entries: [MAX_BIND_GROUPS]?[MAX_BINDINGS]?BindGroupEntry,
    ) !Self {
        slog.debug("Creating Bindings", .{});

        // Even when the buffers are individually dropped, wgpu will keep the bind group and buffers
        // alive until the bind group itself is dropped.
        var bind_groups: [MAX_BIND_GROUPS]?wgpu.BindGroup = @splat(null);
        for (bind_group_entries, 0..) |bind_group, bind_group_number| {
            var wgpu_bind_group_entries: [MAX_BINDINGS]wgpu.BindGroup.Entry = undefined;
            const bg = bind_group orelse continue;
            var bind_count: u32 = 0;
            for (bg, 0..) |bind_group_entry, bind_group_entry_number| {
                const bge = bind_group_entry orelse continue;
                if (bge.texture) |texture| {
                    wgpu_bind_group_entries[bind_group_entry_number] = .{
                        .binding = @intCast(bind_group_entry_number),
                        .texture_view = try texture.texture.createView(.{}),
                    };
                } else if (bge.buffer) |buffer| {
                    if (buffer.buffer_size == 0) {
                        slog.err("Buffer size is 0, cannot bind bind group {d} entry {d} to pipeline", .{ bind_group_number, bind_group_entry_number });
                        return error.InvalidInput;
                    }
                    wgpu_bind_group_entries[bind_group_entry_number] = .{
                        .binding = @intCast(bind_group_entry_number),
                        .buffer = buffer.buffer,
                        .offset = 0,
                        .size = buffer.buffer_size,
                    };
                }
                bind_count += 1;
            }
            const wgpu_bind_group = try gpu.device.createBindGroup(.{
                .label = "Bind Group",
                .layout = compute_pipeline.wgpu_bind_group_layouts[bind_group_number].?,
                .entries = wgpu_bind_group_entries[0..bind_count],
            });
            errdefer wgpu_bind_group.deinit();
            bind_groups[bind_group_number] = wgpu_bind_group;
        }
        return Bindings{
            .bind_groups = bind_groups,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.bind_groups) |bind_group| {
            const bg = bind_group orelse continue;
            bg.deinit();
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

    pub fn toWGPUBufferBindingType(self: BindGroupLayoutBufferEntryType) wgpu.BindGroupLayout.BufferBindingType {
        return switch (self) {
            .storage => .storage,
            .uniform => .uniform,
            // .read_only_storage => .read_only_storage,
        };
    }
};

pub const BindGroupLayoutBufferEntry = struct {
    binding_type: BindGroupLayoutBufferEntryType,
};

pub const BindGroupLayoutEntry = struct {
    texture: ?BindGroupLayoutTextureEntry = null,
    buffer: ?BindGroupLayoutBufferEntry = null,
};

pub const ShaderLanguage = enum {
    wgsl,
    spirv,
    glsl,
};

pub const ShaderSource = union(ShaderLanguage) {
    wgsl: []const u8,
    spirv: []const u32,
    glsl: []const u8,
};

pub const CompileShaderOpts = struct {
    name: []const u8 = "Compute Shader",
    type: ShaderLanguage = .wgsl,
};

pub const Shader = struct {
    shader_module: wgpu.ShaderModule,

    const Self = @This();

    pub fn compile(gpu: *GPU, shader_source: ShaderSource) !Shader {
        slog.debug("Compiling shader", .{});
        const source: wgpu.ShaderSource = switch (shader_source) {
            .wgsl => .{ .wgsl = shader_source.wgsl },
            .spirv => blk: {
                const code_ptr: [*]const u32 = @ptrCast(@alignCast(shader_source.spirv.ptr));
                break :blk .{ .spirv = code_ptr[0 .. shader_source.spirv.len / @sizeOf(u32)] };
            },
            .glsl => .{ .glsl = .{ .code = shader_source.glsl, .stage = .compute } },
        };

        const shader_module = try gpu.device.createShaderModule(source);

        return Self{
            .shader_module = shader_module,
        };
    }

    pub fn deinit(self: *Self) void {
        self.shader_module.deinit();
    }
};

pub const ComputePipeline = struct {
    name: []const u8,
    wgpu_bind_group_layouts: [MAX_BIND_GROUPS]?wgpu.BindGroupLayout,
    pipeline_layout: wgpu.PipelineLayout,
    pipeline: wgpu.ComputePipeline,

    const Self = @This();

    pub fn init(
        gpu: *GPU,
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

        var wgpu_bind_group_layouts: [MAX_BIND_GROUPS]?wgpu.BindGroupLayout = @splat(null);

        var bind_group_layout_count: u32 = 0;
        bgle_blk: for (bind_group_layout_entries, 0..) |bind_group_layout, bind_group_layout_number| {
            const bgl = bind_group_layout orelse break :bgle_blk;
            var wgpu_bind_group_layout_entries: [MAX_BINDINGS]wgpu.BindGroupLayout.Entry = undefined;

            var bind_count: u32 = 0;
            bgl_blk: for (bgl, 0..) |bind_group_layout_entry, bind_number| {
                const bgle = bind_group_layout_entry orelse break :bgl_blk;

                if (bgle.texture) |bgle_texture| {
                    switch (bgle_texture.access) {
                        .read => {
                            // Note: we don't need format for input textures
                            // but we do need to specify the sample type
                            wgpu_bind_group_layout_entries[bind_number] = .{
                                .binding = @intCast(bind_number),
                                .visibility = .{ .compute = true },
                                .texture = .{
                                    .view_dimension = .@"2d",
                                    .sample_type = bgle_texture.format.toWGPUSampleType(),
                                },
                            };
                        },
                        .write => {
                            wgpu_bind_group_layout_entries[bind_number] = .{
                                .binding = @intCast(bind_number),
                                .visibility = .{ .compute = true },
                                .storage_texture = .{
                                    .access = .write_only,
                                    .format = bgle_texture.format.toWGPUFormat(),
                                    .view_dimension = .@"2d",
                                },
                            };
                        },
                    }
                } else if (bgle.buffer) |bgle_buffer| {
                    wgpu_bind_group_layout_entries[bind_number] = .{
                        .binding = @intCast(bind_number),
                        .visibility = .{ .compute = true },
                        .buffer = .{
                            .binding_type = bgle_buffer.binding_type.toWGPUBufferBindingType(),

                            // .has_dynamic_offset = false,
                            // .min_binding_size = bge_buffer.size,
                        },
                    };
                }
                bind_count += 1;
            }
            const wgpu_bind_group_layout = try gpu.device.createBindGroupLayout(.{
                .label = "Bind Group Layout",
                .entries = wgpu_bind_group_layout_entries[0..bind_count],
            });
            errdefer wgpu_bind_group_layout.deinit();

            wgpu_bind_group_layouts[bind_group_layout_number] = wgpu_bind_group_layout;
            bind_group_layout_count += 1;
        }

        // The pipeline layout describes the bind groups that a pipeline expects
        // (only the non-null prefix of bind group layouts)
        const wgpu_pipeline_layout = try gpu.device.createPipelineLayout(
            "Pipeline Layout",
            wgpu_bind_group_layouts[0..bind_group_layout_count],
            0, // immediate_size
        );
        errdefer wgpu_pipeline_layout.deinit();

        // The pipeline is the ready-to-go program state for the GPU. It contains the shader modules,
        // the interfaces (bind group layouts) and the shader entry point.
        // this does some compilation/validation/linking as well
        const pipeline = try gpu.device.createComputePipeline(.{
            .label = "Compute Pipeline",
            .layout = wgpu_pipeline_layout,
            .module = shader.shader_module,
            .entry_point = name,
        });
        errdefer pipeline.deinit();

        return ComputePipeline{
            .name = name,
            .wgpu_bind_group_layouts = wgpu_bind_group_layouts,
            .pipeline_layout = wgpu_pipeline_layout,
            .pipeline = pipeline,
        };
    }

    pub fn deinit(self: *Self) void {
        slog.debug("De-initializing ShaderPass {s}", .{self.name});

        for (self.wgpu_bind_group_layouts) |bind_group_layout| {
            const bgl = bind_group_layout orelse continue;
            bgl.deinit();
        }

        self.pipeline_layout.deinit();
        self.pipeline.deinit();
    }
};

pub const ShaderSourceContext = struct {
    pub fn hash(self: ShaderSourceContext, key: ShaderSource) u64 {
        _ = self;
        var hasher = std.hash.Wyhash.init(0);

        // Hash the active language tag first
        const tag = @as(ShaderLanguage, key);
        hasher.update(std.mem.asBytes(&tag));

        // Safely hash the slice contents based on active variant
        switch (key) {
            .wgsl => |code| hasher.update(code),
            .glsl => |code| hasher.update(code),
            .spirv => |words| {
                // Cast the u32 slice safely to a byte slice for the hasher
                const bytes = std.mem.sliceAsBytes(words);
                hasher.update(bytes);
            },
        }
        return hasher.final();
    }

    pub fn eql(self: ShaderSourceContext, a: ShaderSource, b: ShaderSource) bool {
        _ = self;
        // Verify they are the same language variant
        const tag_a = @as(ShaderLanguage, a);
        const tag_b = @as(ShaderLanguage, b);
        if (tag_a != tag_b) return false;

        // Perform a deep content equality check on the slices
        return switch (a) {
            .wgsl => std.mem.eql(u8, a.wgsl, b.wgsl),
            .glsl => std.mem.eql(u8, a.glsl, b.glsl),
            .spirv => std.mem.eql(u32, a.spirv, b.spirv),
        };
    }
};
pub const ShaderMap = std.HashMap(
    ShaderSource,
    Shader,
    ShaderSourceContext,
    std.hash_map.default_max_load_percentage,
);

/// GPU manages the WebGPU instance, adapter, device, and queue.
pub const GPU = struct {
    instance: ?wgpu.Instance,
    adapter: ?wgpu.Adapter,
    device: wgpu.Device,
    queue: wgpu.Queue,
    adapter_name: []const u8,
    shader_cache: ShaderMap,

    const Self = @This();

    fn adapterLimits(self: *const Self) ?c.WGPULimits {
        const adapter = self.adapter orelse return null;
        return adapter.getLimits() catch null;
    }

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Self {
        _ = io; // not needed by wgpu-native (its futures resolve via device poll / process events)
        // _ = allocator;
        slog.debug("Initializing GPU", .{});

        const instance = try wgpu.Instance.init(null);
        errdefer instance.deinit();

        const adapter = try instance.requestAdapterSync(.{
            .power_preference = .high_performance,
        });
        errdefer adapter.deinit();

        const info = adapter.getInfo() catch {
            slog.err("Failed to get adapter info", .{});
            return error.AdapterInfo;
        };
        slog.info("Using adapter: {s} (backend={s}, type={s})", .{ info.device, @tagName(info.backend_type), @tagName(info.adapter_type) });

        // We then create a `Device` and a `Queue` from the `Adapter`.
        // https://webgpureport.org/
        //
        // The wgpu-zig Device.Descriptor does not (yet) expose required
        // features/limits, so request the device through the C API directly
        // and wrap the handle.
        const required_features = [_]c.WGPUFeatureName{
            c.WGPUFeatureName_ShaderF16, // enable f16 support
            // without this flag, read/write storage access is not allowed at all
            @as(c.WGPUFeatureName, @intCast(c.WGPUNativeFeature_TextureAdapterSpecificFormatFeatures)),
            // .mappable_primary_buffers, // https://docs.rs/wgpu-types/0.7.0/wgpu_types/struct.Features.html#associatedconstant.MAPPABLE_PRIMARY_BUFFERS
        };

        var required_limits = try adapter.getLimits();
        required_limits.maxStorageBufferBindingSize = 1024 * 1024 * 1024; // 1 GB
        required_limits.maxBufferSize = 1024 * 1024 * 1024; // 1 GB

        var device_data = DeviceRequestData{};
        const device_descriptor = c.WGPUDeviceDescriptor{
            .label = stringView("Device"),
            .requiredFeatureCount = required_features.len,
            .requiredFeatures = &required_features,
            .requiredLimits = &required_limits,
            .defaultQueue = .{
                .label = stringView("Queue"),
            },
            .deviceLostCallbackInfo = .{
                .mode = c.WGPUCallbackMode_AllowSpontaneous,
                .callback = deviceLostCb,
            },
            .uncapturedErrorCallbackInfo = .{
                .callback = uncapturedErrorCb,
            },
        };
        _ = c.wgpuAdapterRequestDevice(adapter.adapter, &device_descriptor, .{
            .mode = c.WGPUCallbackMode_AllowSpontaneous,
            .callback = requestDeviceCb,
            .userdata1 = &device_data,
        });
        while (device_data.device == null) {
            c.wgpuInstanceProcessEvents(instance.instance);
        }
        const device = wgpu.Device{
            .device = device_data.device orelse return error.NoDevice,
        };
        errdefer device.deinit();

        const queue = try device.getQueue();
        errdefer queue.deinit();

        const limits = try adapter.getLimits();

        slog.info("Adapter limits:", .{});
        slog.info("- max_bind_groups: {d}", .{limits.maxBindGroups});
        slog.info("- max_bindings_per_bind_group: {d}", .{limits.maxBindingsPerBindGroup});
        slog.info("- max_texture_dimension_2d: {d}", .{limits.maxTextureDimension2D});
        slog.info("- max_compute_invocations_per_workgroup: {d}", .{limits.maxComputeInvocationsPerWorkgroup});
        slog.info("- max_compute_workgroup_size_x: {d}", .{limits.maxComputeWorkgroupSizeX});
        slog.info("- max_compute_workgroup_size_y: {d}", .{limits.maxComputeWorkgroupSizeY});
        slog.info("- max_compute_workgroup_size_z: {d}", .{limits.maxComputeWorkgroupSizeZ});
        slog.info("- max_compute_workgroups_per_dimension: {d}", .{limits.maxComputeWorkgroupsPerDimension});
        slog.info("- max_buffer_size: {B:.2}", .{limits.maxBufferSize});
        slog.info("- max_uniform_buffer_binding_size: {B:.2}", .{limits.maxUniformBufferBindingSize});
        slog.info("- max_storage_buffer_binding_size: {B:.2}", .{limits.maxStorageBufferBindingSize});
        slog.info("- min_uniform_buffer_offset_alignment: {d}", .{limits.minUniformBufferOffsetAlignment});
        slog.info("- min_storage_buffer_offset_alignment: {d}", .{limits.minStorageBufferOffsetAlignment});

        const shader_cache = ShaderMap.init(allocator);

        return Self{
            .instance = instance,
            .adapter = adapter,
            .device = device,
            .queue = queue,
            .adapter_name = info.device,
            .shader_cache = shader_cache,
        };
    }

    pub fn initExternal(allocator: std.mem.Allocator, io: std.Io, device: wgpu.Device, queue: wgpu.Queue) !Self {
        _ = io;
        slog.debug("Initializing GPU from external sokol-owned WebGPU device/queue", .{});
        c.wgpuDeviceAddRef(device.device);
        errdefer device.deinit();
        c.wgpuQueueAddRef(queue.queue);
        errdefer queue.deinit();
        const shader_cache = ShaderMap.init(allocator);
        return .{
            .instance = null,
            .adapter = null,
            .device = device,
            .queue = queue,
            .adapter_name = "sokol-external-device",
            .shader_cache = shader_cache,
        };
    }

    pub fn deinit(self: *Self) void {
        slog.debug("De-initializing GPU", .{});

        self.queue.deinit();
        self.device.deinit();
        if (self.adapter) |adapter| adapter.deinit();
        if (self.instance) |instance| instance.deinit();
        self.shader_cache.deinit();
    }

    pub fn compileShader(self: *Self, shader_source: ShaderSource) !Shader {
        const shader = self.shader_cache.get(shader_source) orelse blk: {
            slog.info("Shader not found in cache, compiling new shader", .{});
            const shader = try Shader.compile(self, shader_source);
            self.shader_cache.put(shader_source, shader) catch {
                slog.err("Failed to cache shader", .{});
            };
            break :blk shader;
        };
        return shader;
    }

    pub fn run(self: *Self, command_buffer: ?wgpu.CommandEncoder.CommandBuffer) !void {
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
        // NOTE: Queue.submitCommands releases the command buffer for us.
        self.queue.submitCommands(&.{command_buffer_unwrapped});
    }
};

// ================
// INTERNAL HELPERS
// ================

fn stringView(s: []const u8) c.WGPUStringView {
    return .{ .data = s.ptr, .length = s.len };
}

const DeviceRequestData = struct {
    device: c.WGPUDevice = null,
};

fn requestDeviceCb(
    status: c.WGPURequestDeviceStatus,
    device_handle: c.WGPUDevice,
    _: c.WGPUStringView,
    userdata1: ?*anyopaque,
    _: ?*anyopaque,
) callconv(.c) void {
    const data: *DeviceRequestData = @ptrCast(@alignCast(userdata1));
    if (status == c.WGPURequestDeviceStatus_Success) {
        data.device = device_handle;
    }
}

fn deviceLostCb(
    _: [*c]const c.WGPUDevice,
    reason: c.WGPUDeviceLostReason,
    message: c.WGPUStringView,
    _: ?*anyopaque,
    _: ?*anyopaque,
) callconv(.c) void {
    const msg = if (message.length > 0) message.data[0..message.length] else "";
    slog.err("Device lost (reason={d}): {s}", .{ reason, msg });
}

fn uncapturedErrorCb(
    _: [*c]const c.WGPUDevice,
    err_type: c.WGPUErrorType,
    message: c.WGPUStringView,
    _: ?*anyopaque,
    _: ?*anyopaque,
) callconv(.c) void {
    if (err_type == c.WGPUErrorType_NoError) return;
    const msg = if (message.length > 0) message.data[0..message.length] else "";
    slog.err("Uncaptured error (type={d}): {s}", .{ err_type, msg });
}
