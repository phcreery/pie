/// A lot of this is just a wrapper around wgpu to make it easier to use in the context of image processing.
const std = @import("std");
const wgpu = @import("wgpu");
const ROI = @import("ROI.zig");

const COPY_BUFFER_ALIGNMENT: u64 = 4; // https://github.com/gfx-rs/wgpu/blob/trunk/wgpu-types/src/lib.rs#L96
const COPY_BYTES_PER_ROW_ALIGNMENT: u32 = 256; // wgpu.COPY_BYTES_PER_ROW_ALIGNMENT

// Workgroup size must match the compute shader
pub const WORKGROUP_SIZE_X: u32 = 8;
pub const WORKGROUP_SIZE_Y: u32 = 8;
pub const WORKGROUP_SIZE_Z: u32 = 1;

fn handleBufferMap(status: wgpu.MapAsyncStatus, _: wgpu.StringView, userdata1: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    // std.log.info("buffer_map status={x:.8}\n", .{@intFromEnum(status)});
    _ = status;
    const complete: *bool = @ptrCast(@alignCast(userdata1));
    complete.* = true;
}

/// Dead simple GPU allocator using an upload and download buffer
/// for staging data to/from the GPU.
/// This is not optimal, but it works for now. Only one allocation at a time.
/// Future work could include a more complex allocator with multiple buffers
/// useful for multiple simultaneous operations.
pub const GPUAllocator = struct {
    upload_buffer: *wgpu.Buffer = undefined,
    download_buffer: *wgpu.Buffer = undefined,
    const Self = @This();
    pub fn init(gpu: *GPU) !Self {
        var limits = wgpu.Limits{};
        _ = gpu.adapter.getLimits(&limits);

        var max_buffer_size = limits.max_buffer_size;
        if (max_buffer_size == wgpu.WGPU_LIMIT_U64_UNDEFINED) {
            // set to something reasonable
            // max_buffer_size = 256 * 1024 * 1024; // 256 MB
            max_buffer_size = 256 * 1024 * 1024 * 12; // 3x256 MB for RGBAf16
        }

        const buffer_size = max_buffer_size / 16;

        // Finally we create a buffer which can be read by the CPU. This buffer is how we will read
        // the data. We need to use a separate buffer because we need to have a usage of `MAP_READ`,
        // and that usage can only be used with `COPY_DST`.
        std.log.info("Creating GPUAllocator with upload buffer size {d} bytes", .{buffer_size});
        const upload_buffer = gpu.device.createBuffer(&wgpu.BufferDescriptor{
            .label = wgpu.StringView.fromSlice("upload_buffer"),
            .usage = wgpu.BufferUsages.copy_src | wgpu.BufferUsages.map_write,
            .size = buffer_size,
            // .mapped_at_creation = @as(u32, @intFromBool(true)),
            .mapped_at_creation = @as(u32, @intFromBool(false)),
        }).?;
        errdefer upload_buffer.release();

        std.log.info("Creating GPUAllocator with download buffer size {d} bytes", .{buffer_size});
        const download_buffer = gpu.device.createBuffer(&wgpu.BufferDescriptor{
            .label = wgpu.StringView.fromSlice("download_buffer"),
            .usage = wgpu.BufferUsages.copy_dst | wgpu.BufferUsages.map_read,
            .size = buffer_size,
            .mapped_at_creation = @as(u32, @intFromBool(false)),
        }).?;
        errdefer download_buffer.release();

        return Self{
            .upload_buffer = upload_buffer,
            .download_buffer = download_buffer,
        };
    }

    pub fn deinit(self: *Self) void {
        self.download_buffer.release();
        self.upload_buffer.release();
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

    /// you need to submit the command buffer to the GPU queue after finishing
    pub fn finish(self: *Self) ?*wgpu.CommandBuffer {
        std.log.info("Submitting command buffer to GPU", .{});

        // We finish the encoder, giving us a fully recorded command buffer.
        const command_buffer = self.encoder.finish(&wgpu.CommandBufferDescriptor{
            .label = wgpu.StringView.fromSlice("Command Buffer"),
        }).?;

        // the command buffer need to be released after submitting with command_buffer.release()
        // GPU.run() will do that for you
        return command_buffer;
    }

    pub fn enqueueShader(self: *Self, shader_pipe: *const ShaderPipe, bindings: *Bindings, work_size: ROI) void {
        std.log.info("Enqueuing compute shader", .{});
        // A compute pass is a single series of compute operations. While we are recording a compute
        // pass, we cannot record to the encoder.
        const compute_pass = self.encoder.beginComputePass(&wgpu.ComputePassDescriptor{
            .label = wgpu.StringView.fromSlice("Compute Pass"),
        }).?;
        // Set the pipeline that we want to use
        compute_pass.setPipeline(shader_pipe.pipeline);
        compute_pass.setBindGroup(0, bindings.bind_group, 0, null);

        // Now we dispatch a series of workgroups. Each workgroup is a 3D grid of individual programs.
        //
        // If the user passes 32 inputs, we will
        // dispatch 1 workgroups. If the user passes 65 inputs, we will dispatch 2 workgroups, etc.
        const workgroup_count_x = (work_size.size.w + WORKGROUP_SIZE_X - 1) / WORKGROUP_SIZE_X; // ceil division
        const workgroup_count_y = (work_size.size.h + WORKGROUP_SIZE_Y - 1) / WORKGROUP_SIZE_Y; // ceil division
        const workgroup_count_z = 1;

        { // Debug info
            // const output_size = work_size.size.w * work_size.size.h;
            // const workgroup_size = WORKGROUP_SIZE_X * WORKGROUP_SIZE_Y * WORKGROUP_SIZE_Z;
            // std.log.info("output_size: {d}", .{output_size});
            // std.log.info("workgroup_size: {d}", .{workgroup_size});
            // std.log.info("workgroup_count_x: {d}", .{workgroup_count_x});
            // std.log.info("workgroup_count_y: {d}", .{workgroup_count_y});
            // std.log.info("workgroup_count_z: {d}", .{workgroup_count_z});
            // std.log.info("total workgroups: {d}", .{workgroup_count_x * workgroup_count_y * workgroup_count_z});
            // std.log.info("total invocations: {d}", .{@as(u32, workgroup_count_x) * workgroup_count_y * workgroup_count_z * workgroup_size});
        }

        std.log.info("Dispatching compute work", .{});
        compute_pass.dispatchWorkgroups(workgroup_count_x, workgroup_count_y, workgroup_count_z);
        // Now we drop the compute pass, giving us access to the encoder again.
        compute_pass.end();
    }

    pub fn enqueueBufToTex(self: *Self, allocator: *GPUAllocator, texture: *Texture, roi: ROI) !void {
        std.log.info("Writing GPU buffer to Shader Buffer", .{});

        // check bytes_per_row is a multiple of 256
        const bytes_per_row = roi.size.w * texture.format.bpp();
        const padded_bytes_per_row = ((bytes_per_row + COPY_BYTES_PER_ROW_ALIGNMENT - 1) / COPY_BYTES_PER_ROW_ALIGNMENT) * COPY_BYTES_PER_ROW_ALIGNMENT; // ceil to next multiple of 256

        // We add a copy operation to the encoder. This will copy the data from the upload buffer on the
        // CPU to the input buffer on the GPU.
        const copy_size = wgpu.Extent3D{
            .width = roi.size.w,
            .height = roi.size.h,
            .depth_or_array_layers = 1,
        };
        const offset = @as(u64, roi.origin.y) * padded_bytes_per_row + roi.origin.x * texture.format.bpp();
        const source = wgpu.TexelCopyBufferInfo{
            .buffer = allocator.upload_buffer,
            .layout = wgpu.TexelCopyBufferLayout{
                .offset = offset,
                .bytes_per_row = padded_bytes_per_row,
                .rows_per_image = roi.size.h,
            },
        };
        { // Debug info
            // std.log.info("[enqueueMount] copy_size.width: {d}", .{copy_size.width});
            // std.log.info("[enqueueMount] copy_size.height: {d}", .{copy_size.height});
            // std.log.info("[enqueueMount] copy_size.depth_or_array_layers: {d}", .{copy_size.depth_or_array_layers});
            // std.log.info("[enqueueMount] offset: {d}", .{offset});
            // std.log.info("[enqueueMount] source.buffer size: {d}", .{self.upload_buffer.getSize()});
            // std.log.info("[enqueueMount] source.layout.bytes_per_row: {d}", .{source.layout.bytes_per_row});
            // std.log.info("[enqueueMount] source.layout.rows_per_image: {d}", .{source.layout.rows_per_image});
        }
        const destination = wgpu.TexelCopyTextureInfo{
            .texture = texture.texture,
            .mip_level = 0,
            // .origin = wgpu.Origin3D{ .x = roi.origin.x, .y = roi.origin.y, .z = 0 },
            .origin = wgpu.Origin3D{ .x = 0, .y = 0, .z = 0 },
        };
        self.encoder.copyBufferToTexture(&source, &destination, &copy_size);
    }
    pub fn enqueueTexToBuf(self: *Self, allocator: *GPUAllocator, texture: *Texture, roi: ROI) !void {
        std.log.info("Reading GPU buffer from Shader Buffer", .{});

        // check bytes_per_row is a multiple of 256
        const bytes_per_row = roi.size.w * texture.format.bpp();
        // if (bytes_per_row % 256 != 0) {
        //     std.log.err("bytes_per_row must be a multiple of 256, got {d}", .{bytes_per_row});
        //     return error.InvalidInput;
        // }
        const padded_bytes_per_row = ((bytes_per_row + COPY_BYTES_PER_ROW_ALIGNMENT - 1) / COPY_BYTES_PER_ROW_ALIGNMENT) * COPY_BYTES_PER_ROW_ALIGNMENT; // ceil to next multiple of 256

        // We add a copy operation to the encoder. This will copy the data from the output buffer on the
        // GPU to the download buffer on the CPU.
        // self.encoder.copyBufferToBuffer(self.buffer[self.dst_index], 0, self.download_buffer, 0, self.buffer[self.dst_index].getSize());
        // const copy_size = self.textures[self.dst_index].getWidth() * self.textures[self.dst_index].getHeight() * 4; // width * height * RGBA
        const copy_size = wgpu.Extent3D{
            .width = roi.size.w,
            .height = roi.size.h,
            .depth_or_array_layers = 1,
        };
        const source = wgpu.TexelCopyTextureInfo{
            .texture = texture.texture,
            .mip_level = 0,
            // .origin = wgpu.Origin3D{ .x = src_origin.x, .y = src_origin.y, .z = 0 },
            .origin = wgpu.Origin3D{ .x = 0, .y = 0, .z = 0 },
        };
        const offset = @as(u64, roi.origin.y) * padded_bytes_per_row + roi.origin.x * texture.format.bpp();
        const destination = wgpu.TexelCopyBufferInfo{
            .buffer = allocator.download_buffer,
            .layout = wgpu.TexelCopyBufferLayout{
                // .offset = 0,
                .offset = offset,
                .bytes_per_row = padded_bytes_per_row,
                .rows_per_image = roi.size.h,
            },
        };
        { // Debug info
            // std.log.info("[enqueueUnmount] copy_size.width: {d}", .{copy_size.width});
            // std.log.info("[enqueueUnmount] copy_size.height: {d}", .{copy_size.height});
            // std.log.info("[enqueueUnmount] copy_size.depth_or_array_layers: {d}", .{copy_size.depth_or_array_layers});
            // std.log.info("[enqueueUnmount] offset: {d}", .{offset});
            // std.log.info("[enqueueUnmount] destination.buffer size: {d}", .{self.download_buffer.getSize()});
            // std.log.info("[enqueueUnmount] destination.layout.bytes_per_row: {d}", .{destination.layout.bytes_per_row});
            // std.log.info("[enqueueUnmount] destination.layout.rows_per_image: {d}", .{destination.layout.rows_per_image});
        }
        self.encoder.copyTextureToBuffer(&source, &destination, &copy_size);
    }

    pub fn enqueueTexToTex(self: *Self, src_texture: *Texture, dst_texture: *Texture, roi: ROI) !void {
        std.log.info("Copying GPU texture to another GPU texture", .{});

        const copy_size = wgpu.Extent3D{
            .width = roi.size.w,
            .height = roi.size.h,
            .depth_or_array_layers = 1,
        };
        const source = wgpu.TexelCopyTextureInfo{
            .texture = src_texture.texture,
            .mip_level = 0,
            // .origin = wgpu.Origin3D{ .x = roi.origin.x, .y = roi.origin.y, .z = 0 },
            .origin = wgpu.Origin3D{ .x = 0, .y = 0, .z = 0 },
        };

        const destination = wgpu.TexelCopyTextureInfo{
            .texture = dst_texture.texture,
            .mip_level = 0,
            // .origin = wgpu.Origin3D{ .x = roi.origin.x, .y = roi.origin.y, .z = 0 },
            .origin = wgpu.Origin3D{ .x = 0, .y = 0, .z = 0 },
        };

        self.encoder.copyTextureToTexture(&source, &destination, &copy_size);
    }
};

pub const TextureFormat = enum {
    rgba16float,
    rgba16uint,
    r8uint,
    r16uint,
    r16float,

    pub fn toWGPUFormat(self: TextureFormat) wgpu.TextureFormat {
        return switch (self) {
            .rgba16float => wgpu.TextureFormat.rgba16_float,
            .rgba16uint => wgpu.TextureFormat.rgba16_uint,
            .r8uint => wgpu.TextureFormat.r8_uint,
            .r16uint => wgpu.TextureFormat.r16_uint,
            .r16float => wgpu.TextureFormat.r16_float,
        };
    }

    pub fn toWGPUSampleType(self: TextureFormat) wgpu.SampleType {
        return switch (self) {
            .rgba16float => wgpu.SampleType.float,
            .rgba16uint => wgpu.SampleType.u_int,
            .r8uint => wgpu.SampleType.u_int,
            .r16uint => wgpu.SampleType.u_int,
            .r16float => wgpu.SampleType.float,
        };
    }

    // TODO: make to following functions comptime accessible

    /// bytes per pixel
    pub fn bpp(self: TextureFormat) u32 {
        // return self.nchannels() * @sizeOf(self.BaseType()); // requires comtime param
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
        };
    }

    /// base type
    pub fn BaseType(self: TextureFormat) type {
        return switch (self) {
            .rgba16float => f16,
            .rgba16uint => u16,
            .r8uint => u8,
            .r16uint => u16,
            .r16float => f16,
        };
    }

    pub fn baseTypeSize(self: TextureFormat) u32 {
        return switch (self) {
            .rgba16float => @sizeOf(f16),
            .rgba16uint => @sizeOf(u16),
            .r8uint => @sizeOf(u8),
            .r16uint => @sizeOf(u16),
            .r16float => @sizeOf(f16),
        };
    }
};

pub const Texture = struct {
    texture: *wgpu.Texture = undefined,
    format: TextureFormat = .rgba16float,
    const Self = @This();

    pub fn init(gpu: *GPU, format: TextureFormat, roi: ROI) !Self {
        std.log.info("Creating texture {s} of size {d}x{d}", .{ @tagName(format), roi.size.w, roi.size.h });
        var limits = wgpu.Limits{};
        _ = gpu.adapter.getLimits(&limits);

        // r16uint does not support storage binding
        var usage = wgpu.TextureUsages.storage_binding | wgpu.TextureUsages.texture_binding | wgpu.TextureUsages.copy_src | wgpu.TextureUsages.copy_dst;
        if (format == .r16uint or format == .r16float) {
            usage = wgpu.TextureUsages.texture_binding | wgpu.TextureUsages.copy_src | wgpu.TextureUsages.copy_dst;
        }

        const texture = gpu.device.createTexture(&wgpu.TextureDescriptor{
            .label = wgpu.StringView.fromSlice("input_texture"),
            .size = wgpu.Extent3D{
                // .width = limits.max_texture_dimension_2d / 2,
                // .height = limits.max_texture_dimension_2d / 2,
                .width = roi.size.w,
                .height = roi.size.h,
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
        };
    }

    pub fn deinit(self: *Self) void {
        self.texture.release();
    }
};

pub const Bindings = struct {
    bind_group: *wgpu.BindGroup = undefined,
    const Self = @This();

    pub fn init(gpu: *GPU, shader_pipe: *const ShaderPipe, texture_a: *Texture, texture_b: *Texture) !Self {
        std.log.info("Creating Bindings", .{});
        var limits = wgpu.Limits{};
        _ = gpu.adapter.getLimits(&limits);

        // The bind group contains the actual resources to bind to the pipeline.

        // Even when the buffers are individually dropped, wgpu will keep the bind group and buffers
        // alive until the bind group itself is dropped.
        const bind_group_entries_a_to_b = [_]wgpu.BindGroupEntry{
            // Binding 0: input storage buffer
            wgpu.BindGroupEntry{
                .binding = 0,
                .texture_view = texture_a.texture.createView(null),
                // .offset = 0,
                // .size = texture_a.texture.getWidth() * texture_a.texture.getHeight() * 4, // width * height * RGBA
            },
            // Binding 1: output storage buffer
            wgpu.BindGroupEntry{
                .binding = 1,
                .texture_view = texture_b.texture.createView(null),
                // .offset = 0,
                // .size = texture_b.texture.getWidth() * texture_b.texture.getHeight() * 4, // width * height * RGBA
            },
        };
        const bind_group = gpu.device.createBindGroup(&wgpu.BindGroupDescriptor{
            .label = wgpu.StringView.fromSlice("Bind Group 1"),
            .layout = shader_pipe.bind_group_layout,
            .entry_count = 2,
            .entries = &bind_group_entries_a_to_b,
        }).?;
        errdefer bind_group.release();
        return Bindings{
            .bind_group = bind_group,
        };
    }

    pub fn deinit(self: *Self) void {
        self.bind_group.release();
    }
};

pub const ShaderPipeConnType = enum {
    input,
    output,
};

pub const ShaderPipeConn = struct {
    binding: u32,
    type: ShaderPipeConnType,
    format: TextureFormat,
};
pub const ShaderPipeParams = struct {
    binding: u32,
    format: TextureFormat,
};

pub const ShaderPipe = struct {
    entry_point: []const u8,
    bind_group_layout: *wgpu.BindGroupLayout,
    shader_module: *wgpu.ShaderModule,
    pipeline_layout: *wgpu.PipelineLayout,
    pipeline: *wgpu.ComputePipeline,

    const Self = @This();

    pub fn init(gpu: *GPU, shader_source: []const u8, entry_point: []const u8, g0_conns: [2]ShaderPipeConn) !Self {
        std.log.info("Initializing ShaderPipe for {s}", .{entry_point});

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
        //
        // TODO: make this dynamic based on the shader inputs/outputs `[g0_conns.len]wgpu.BindGroupLayoutEntry`
        var bind_group_layout_entries_g0 = std.mem.zeroes([2]wgpu.BindGroupLayoutEntry);

        for (g0_conns) |conn| {
            switch (conn.type) {
                ShaderPipeConnType.input => {
                    // Note: we don't need format for input textures
                    const entry = wgpu.BindGroupLayoutEntry{
                        .binding = conn.binding,
                        .visibility = wgpu.ShaderStages.compute,
                        .texture = wgpu.TextureBindingLayout{
                            .view_dimension = wgpu.ViewDimension.@"2d",
                            .sample_type = conn.format.toWGPUSampleType(),
                        },
                    };
                    bind_group_layout_entries_g0[conn.binding] = entry;
                    std.log.info("Added input binding {d} sample type {s}", .{ conn.binding, @tagName(conn.format.toWGPUSampleType()) });
                },
                ShaderPipeConnType.output => {
                    const entry = wgpu.BindGroupLayoutEntry{
                        .binding = conn.binding,
                        .visibility = wgpu.ShaderStages.compute,
                        .storage_texture = wgpu.StorageTextureBindingLayout{
                            .access = wgpu.StorageTextureAccess.write_only,
                            .format = conn.format.toWGPUFormat(),
                            .view_dimension = wgpu.ViewDimension.@"2d",
                        },
                    };
                    bind_group_layout_entries_g0[conn.binding] = entry;
                    std.log.info("Added output binding {d} format {s}", .{ conn.binding, @tagName(conn.format.toWGPUFormat()) });
                },
            }
        }

        const bind_group_layout_g0 = gpu.device.createBindGroupLayout(&wgpu.BindGroupLayoutDescriptor{
            // .label = wgpu.StringView.fromSlice("Bind Group Layout for " ++ entry_point),
            .label = wgpu.StringView.fromSlice("Bind Group Layout"),
            .entry_count = 2,
            .entries = &bind_group_layout_entries_g0,
        }).?;
        errdefer bind_group_layout_g0.release();

        // TODO: Cache the pipeline and layout for each shader module and entry point combination.
        // The pipeline layout describes the bind groups that a pipeline expects
        const bind_group_layouts = [_]*wgpu.BindGroupLayout{bind_group_layout_g0};
        const pipeline_layout = gpu.device.createPipelineLayout(&wgpu.PipelineLayoutDescriptor{
            // .label = wgpu.StringView.fromSlice("Pipeline Layout for " ++ entry_point),
            .label = wgpu.StringView.fromSlice("Pipeline Layout"),
            .bind_group_layout_count = 1,
            .bind_group_layouts = &bind_group_layouts,
        }).?;
        errdefer pipeline_layout.release();

        std.log.info("Compiling shader for {s}", .{entry_point});

        // Create the shader module from WGSL source code.
        // You can also load SPIR-V or use the Naga IR.
        const shader_module = gpu.device.createShaderModule(&wgpu.shaderModuleWGSLDescriptor(.{
            // .label = "Compute Shader for " ++ entry_point,
            .label = "Compute Shader",
            .code = shader_source,
        })).?;

        // The pipeline is the ready-to-go program state for the GPU. It contains the shader modules,
        // the interfaces (bind group layouts) and the shader entry point.
        const pipeline = gpu.device.createComputePipeline(&wgpu.ComputePipelineDescriptor{
            // .label = wgpu.StringView.fromSlice("Compute Pipeline for " ++ entry_point),
            .label = wgpu.StringView.fromSlice("Compute Pipeline"),
            .layout = pipeline_layout,
            .compute = wgpu.ProgrammableStageDescriptor{
                .module = shader_module,
                .entry_point = wgpu.StringView.fromSlice(entry_point),
            },
        }).?;
        errdefer pipeline.release();

        return ShaderPipe{
            .entry_point = entry_point,
            .bind_group_layout = bind_group_layout_g0,
            .shader_module = shader_module,
            .pipeline_layout = pipeline_layout,
            .pipeline = pipeline,
        };
    }

    pub fn deinit(self: *Self) void {
        std.log.info("Deinitializing ShaderPass {s}", .{self.entry_point});

        self.bind_group_layout.release();

        self.shader_module.release();
        self.pipeline_layout.release();
        self.pipeline.release();
    }
};

/// GPU manages the WebGPU instance, adapter, device, and queue.
///
/// We are going to do a double buffered setup where we have three buffers:
/// 1. Buffer A: This is a storage buffer that the compute shader reads/writes.
/// 2. Buffer B: This is a storage buffer that the compute shader reads/writes.
/// 3. Download buffer: This is a buffer that we copy the output buffer to so the CPU can read it.
///
/// The idea is that we will run the compute shader multiple times. First off, with buffer A as input and buffer B
/// as output, then with buffer B as input and buffer A as output, and so on. After the final compute pass, we copy
/// the output buffer to the download buffer.
///
/// This is accomplished by creating two bind groups, one for each combination of input/output buffers. We then
/// alternate between the two bind groups for each compute pass. This becomes completely transparent to the CPU
/// and shader code.
///
/// For now, we will be dealing with f32 data
pub const GPU = struct {
    instance: *wgpu.Instance = undefined,
    adapter: *wgpu.Adapter = undefined,
    device: *wgpu.Device = undefined,
    queue: *wgpu.Queue = undefined,
    // upload_buffer: *wgpu.Buffer = undefined,
    // download_buffer: *wgpu.Buffer = undefined,
    // encoder: *wgpu.CommandEncoder = undefined,
    adapter_name: []const u8 = "",

    const Self = @This();

    pub fn init() !Self {
        std.log.info("Initializing GPU", .{});

        const instance = wgpu.Instance.create(null).?;
        errdefer instance.release();

        const adapter_request = instance.requestAdapterSync(&wgpu.RequestAdapterOptions{}, 0);
        const adapter = switch (adapter_request.status) {
            .success => adapter_request.adapter.?,
            else => return error.NoAdapter,
        };
        errdefer adapter.release();

        var info: wgpu.AdapterInfo = undefined;
        const status = adapter.getInfo(&info);
        if (status != .success) {
            std.log.info("Failed to get adapter info", .{});
            return error.AdapterInfo;
        } else {
            const name = info.device.toSlice();
            if (name) |value| {
                std.log.info("Using adapter: {s} (backend={s}, type={s})", .{ value, @tagName(info.backend_type), @tagName(info.adapter_type) });
            } else {
                std.log.info("Failed to get adapter name", .{});
            }
        }

        // We then create a `Device` and a `Queue` from the `Adapter`.
        const required_features = [_]wgpu.FeatureName{ .shader_f16, .texture_adapter_specific_format_features };
        const device_request = adapter.requestDeviceSync(instance, &wgpu.DeviceDescriptor{ .required_limits = null, .required_features = &required_features }, 0);
        const device = switch (device_request.status) {
            .success => device_request.device.?,
            else => return error.NoDevice,
        };
        errdefer device.release();

        const queue = device.getQueue().?;
        errdefer queue.release();

        var limits = wgpu.Limits{};
        _ = adapter.getLimits(&limits);

        std.log.info("Adapter limits:", .{});
        std.log.info(" max_bind_groups: {d}", .{limits.max_bind_groups});
        std.log.info(" max_bindings_per_bind_group: {d}", .{limits.max_bindings_per_bind_group});
        std.log.info(" max_texture_dimension_1d: {d}", .{limits.max_texture_dimension_1d});
        std.log.info(" max_texture_dimension_2d: {d}", .{limits.max_texture_dimension_2d});
        std.log.info(" max_texture_dimension_3d: {d}", .{limits.max_texture_dimension_3d});
        std.log.info(" max_texture_array_layers: {d}", .{limits.max_texture_array_layers});
        std.log.info(" max_compute_invocations_per_workgroup: {d}", .{limits.max_compute_invocations_per_workgroup});
        std.log.info(" max_compute_workgroup_size_x: {d}", .{limits.max_compute_workgroup_size_x});
        std.log.info(" max_compute_workgroup_size_y: {d}", .{limits.max_compute_workgroup_size_y});
        std.log.info(" max_compute_workgroup_size_z: {d}", .{limits.max_compute_workgroup_size_z});
        std.log.info(" max_compute_workgroups_per_dimension: {d}", .{limits.max_compute_workgroups_per_dimension});
        std.log.info(" max_buffer_size: {d}", .{limits.max_buffer_size});
        std.log.info(" max_uniform_buffer_binding_size: {d}", .{limits.max_uniform_buffer_binding_size});
        std.log.info(" max_storage_buffer_binding_size: {d}", .{limits.max_storage_buffer_binding_size});

        // var max_buffer_size = limits.max_buffer_size;
        // if (max_buffer_size == wgpu.WGPU_LIMIT_U64_UNDEFINED) {
        //     // set to something reasonable
        //     // max_buffer_size = 256 * 1024 * 1024; // 256 MB
        //     max_buffer_size = 256 * 1024 * 1024 * 12; // 3x256 MB for RGBAf16
        // }

        // // Finally we create a buffer which can be read by the CPU. This buffer is how we will read
        // // the data. We need to use a separate buffer because we need to have a usage of `MAP_READ`,
        // // and that usage can only be used with `COPY_DST`.
        // const upload_buffer = device.createBuffer(&wgpu.BufferDescriptor{
        //     .label = wgpu.StringView.fromSlice("upload_buffer"),
        //     .usage = wgpu.BufferUsages.copy_src | wgpu.BufferUsages.map_write,
        //     .size = max_buffer_size / 16,
        //     .mapped_at_creation = @as(u32, @intFromBool(true)),
        // }).?;
        // errdefer upload_buffer.release();
        // const download_buffer = device.createBuffer(&wgpu.BufferDescriptor{
        //     .label = wgpu.StringView.fromSlice("download_buffer"),
        //     .usage = wgpu.BufferUsages.copy_dst | wgpu.BufferUsages.map_read,
        //     .size = max_buffer_size / 16,
        //     .mapped_at_creation = @as(u32, @intFromBool(false)),
        // }).?;
        // errdefer download_buffer.release();

        // const upload_texture = device.createTexture(&wgpu.TextureDescriptor{
        //     .label = wgpu.StringView.fromSlice("upload_texture"),
        //     .size = wgpu.Extent3D{
        //         .width = limits.max_texture_dimension_2d / 2,
        //         .height = limits.max_texture_dimension_2d / 2,
        //         .depth_or_array_layers = 1,
        //     },
        //     .mip_level_count = 1,
        //     .sample_count = 1,
        //     .dimension = wgpu.TextureDimension.@"2d",
        //     .format = wgpu.TextureFormat.rgba16_float,
        //     .usage = wgpu.TextureUsages.copy_src | wgpu.TextureUsages.copy_dst,
        // }).?;

        // // The command encoder allows us to record commands that we will later submit to the GPU.
        // const encoder = device.createCommandEncoder(&wgpu.CommandEncoderDescriptor{
        //     .label = wgpu.StringView.fromSlice("Command Encoder"),
        // }).?;
        // errdefer encoder.release();

        return Self{
            .instance = instance,
            .adapter = adapter,
            .device = device,
            .queue = queue,
            .adapter_name = info.device.toSlice() orelse "Unknown",
        };
    }

    pub fn deinit(self: *Self) void {
        std.log.info("Deinitializing GPU", .{});

        self.queue.release();
        self.device.release();
        self.adapter.release();
        self.instance.release();
    }

    pub fn run(self: *Self, command_buffer: ?*wgpu.CommandBuffer) !void {
        std.log.info("Submitting command buffer to GPU", .{});

        const command_buffer_unwrapped = command_buffer orelse {
            std.log.err("No command buffer provided to GPU.run", .{});
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

    pub fn mapUpload(self: *Self, allocator: *GPUAllocator, comptime T: type, data: []const T, comptime format: TextureFormat, roi: ROI) void {
        std.log.info("Writing data to GPU buffers", .{});

        // const size_nvals = roi.size.w * roi.size.h * format.nchannels();
        const size_bytes = roi.size.w * roi.size.h * format.bpp();

        std.log.info(" mapUpload size_bytes: {d}", .{size_bytes});

        // TODO: first check mapped status
        // https://github.com/gfx-rs/wgpu-native/blob/d8238888998db26ceab41942f269da0fa32b890c/src/unimplemented.rs#L25

        // We now map the upload buffer so we can write to it. Mapping tells wgpu that we want to read/write
        // to the buffer directly by the CPU and it should not permit any more GPU operations on the buffer.
        //
        // Mapping requires that the GPU be finished using the buffer before it resolves, so mapping has a callback
        // to tell you when the mapping is complete.
        var buffer_map_complete = false;
        _ = allocator.upload_buffer.mapAsync(wgpu.MapModes.write, 0, size_bytes, wgpu.BufferMapCallbackInfo{
            .callback = handleBufferMap,
            .userdata1 = @ptrCast(&buffer_map_complete),
        });

        // Wait for the GPU to finish working on the submitted work. This doesn't work on WebGPU, so we would need
        // to rely on the callback to know when the buffer is mapped.
        self.instance.processEvents();
        while (!buffer_map_complete) {
            self.instance.processEvents();
        }
        // _ = device.poll(true, null);

        const upload_buffer_ptr: [*]T = @ptrCast(@alignCast(allocator.upload_buffer.getMappedRange(0, size_bytes).?));
        defer allocator.upload_buffer.unmap();
        @memcpy(upload_buffer_ptr, data);
    }

    /// Alternative mapUpload that writes directly to a texture
    /// we aren't really using this now because there isn't an equivalent readTexture method
    pub fn mapUploadTexture(self: *Self, comptime T: type, data: []const T, texture: Texture, comptime format: TextureFormat, roi: ROI) void {
        std.log.info("Writing data to GPU Texture", .{});

        const bytes_per_row = roi.size.w * format.bpp();
        const data_size: usize = roi.size.w * roi.size.h * format.bpp();
        const offset = @as(u64, roi.origin.y) * bytes_per_row + roi.origin.x * format.bpp();
        const data_layout = wgpu.TexelCopyBufferLayout{
            .offset = offset,
            .bytes_per_row = bytes_per_row,
            .rows_per_image = roi.size.h,
        };

        const copy_size = wgpu.Extent3D{
            .width = roi.size.w,
            .height = roi.size.h,
            .depth_or_array_layers = 1,
        };
        const destination = wgpu.TexelCopyTextureInfo{
            .texture = texture.texture,
            .mip_level = 0,
            // .origin = wgpu.Origin3D{ .x = roi.origin.x, .y = roi.origin.y, .z = 0 },
            .origin = wgpu.Origin3D{ .x = 0, .y = 0, .z = 0 },
        };

        self.queue.writeTexture(
            destination,
            @ptrCast(data.ptr),
            data_size,
            data_layout,
            copy_size,
        );
    }
    pub fn mapDownload(self: *Self, allocator: *GPUAllocator, comptime T: type, comptime format: TextureFormat, roi: ROI) ![]T {
        std.log.info("Reading data from GPU buffers", .{});

        // TODO: first check mapped status
        // https://github.com/gfx-rs/wgpu-native/blob/d8238888998db26ceab41942f269da0fa32b890c/src/unimplemented.rs#L25

        const size_nvals = roi.size.w * roi.size.h * format.nchannels();
        const size_bytes = roi.size.w * roi.size.h * format.bpp();

        // We now map the download buffer so we can read it. Mapping tells wgpu that we want to read/write
        // to the buffer directly by the CPU and it should not permit any more GPU operations on the buffer.
        //
        // Mapping requires that the GPU be finished using the buffer before it resolves, so mapping has a callback
        // to tell you when the mapping is complete.
        var buffer_map_complete = false;
        _ = allocator.download_buffer.mapAsync(wgpu.MapModes.read, 0, size_bytes, wgpu.BufferMapCallbackInfo{
            .callback = handleBufferMap,
            .userdata1 = @ptrCast(&buffer_map_complete),
        });

        // Wait for the GPU to finish working on the submitted work. This doesn't work on WebGPU, so we would need
        // to rely on the callback to know when the buffer is mapped.
        self.instance.processEvents();
        while (!buffer_map_complete) {
            self.instance.processEvents();
        }
        // _ = device.poll(true, null);

        // We can now read the data from the buffer.
        // Convert the data back to a slice of f16.
        const download_buffer_ptr: [*]T = @ptrCast(@alignCast(allocator.download_buffer.getMappedRange(0, size_bytes).?));
        defer allocator.download_buffer.unmap();

        const result = download_buffer_ptr[0..size_nvals];
        return result;
    }

    // Helper functions to create ShaderPipe, Texture, and Bindings
    // pub fn createShaderPipe(self: *Self, shader_source: []const u8, entry_point: []const u8, comptime g0_conns: []const ShaderPipeConn) !ShaderPipe {
    //     return ShaderPipe.init(self, shader_source, entry_point, g0_conns);
    // }
    // pub fn createTexture(self: *Self, format: TextureFormat, roi: ROI) !Texture {
    //     return Texture.init(self, format, roi);
    // }
    // pub fn createBindings(self: *Self, shader_pipe: *ShaderPipe, texture_a: *Texture, texture_b: *Texture) !Bindings {
    //     return Bindings.init(self, shader_pipe, texture_a, texture_b);
    // }
};
