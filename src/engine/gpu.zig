const std = @import("std");
const wgpu = @import("wgpu");

const COPY_BUFFER_ALIGNMENT: u64 = 4; // https://github.com/gfx-rs/wgpu/blob/trunk/wgpu-types/src/lib.rs#L96
pub const BYTES_PER_PIXEL_RGBAf16: u32 = 8; // RGBAf16

// Workgroup size must match the compute shader
pub const WORKGROUP_SIZE_X: u32 = 8;
pub const WORKGROUP_SIZE_Y: u32 = 8;
pub const WORKGROUP_SIZE_Z: u32 = 1;

fn handleBufferMap(status: wgpu.MapAsyncStatus, _: wgpu.StringView, userdata1: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    std.log.info("buffer_map status={x:.8}\n", .{@intFromEnum(status)});
    const complete: *bool = @ptrCast(@alignCast(userdata1));
    complete.* = true;
}

pub const CopyRegionParams = struct {
    w: u32,
    h: u32,
};

pub const ShaderPipe = struct {
    textures: [2]*wgpu.Texture = [_]*wgpu.Texture{ undefined, undefined },
    bind_group_layout: *wgpu.BindGroupLayout = undefined,
    bind_groups: [2]*wgpu.BindGroup = [_]*wgpu.BindGroup{ undefined, undefined },
    shader_module: *wgpu.ShaderModule,
    pipeline_layout: *wgpu.PipelineLayout = undefined,
    pipeline: *wgpu.ComputePipeline,
    is_swapped: bool = false,

    const Self = @This();

    pub fn init(gpu: *GPU, shader_source: []const u8, entry_point: []const u8) !Self {
        std.log.info("Initializing ShaderPass", .{});

        var limits = wgpu.Limits{};
        _ = gpu.adapter.getLimits(&limits);

        // A bind group layout describes the types of resources that a bind group can contain. Think
        // of this like a C-style header declaration, ensuring both the pipeline and bind group agree
        // on the types of resources.
        //
        // Note, we are using a texture in binding 0 and a storage texture in binding 1.
        // this is because readable storage textures are not supported in WebGPU unless you enable
        // (readonly_and_readwrite_storage_textures).
        // This is also done in vkdt
        //
        // TODO: create multiple bind groups/layouts for different shader needs and oversized buffers
        const bind_group_layout_entries = &[_]wgpu.BindGroupLayoutEntry{
            // Binding 0: input storage buffer
            wgpu.BindGroupLayoutEntry{
                .binding = 0,
                .visibility = wgpu.ShaderStages.compute,
                .texture = wgpu.TextureBindingLayout{
                    .view_dimension = wgpu.ViewDimension.@"2d",
                },
            },
            // Binding 1: output storage buffer
            wgpu.BindGroupLayoutEntry{
                .binding = 1,
                .visibility = wgpu.ShaderStages.compute,
                // .buffer = wgpu.BufferBindingLayout{
                //     .type = wgpu.BufferBindingType.storage,
                //     .has_dynamic_offset = @as(u32, @intFromBool(false)),
                // },
                // .texture = wgpu.TextureBindingLayout{
                //     // .sample_type = wgpu.SampleType.float,
                //     .view_dimension = wgpu.ViewDimension.@"2d",
                //     // .multisampled = @as(u32, @intFromBool(false)),
                // },
                .storage_texture = wgpu.StorageTextureBindingLayout{
                    .access = wgpu.StorageTextureAccess.write_only,
                    .format = wgpu.TextureFormat.rgba16_float,
                    .view_dimension = wgpu.ViewDimension.@"2d",
                },
            },
        };
        const bind_group_layout = gpu.device.createBindGroupLayout(&wgpu.BindGroupLayoutDescriptor{
            .label = wgpu.StringView.fromSlice("Bind Group Layout"),
            .entry_count = 2,
            .entries = bind_group_layout_entries,
        }).?;
        errdefer bind_group_layout.release();

        const texture_a = gpu.device.createTexture(&wgpu.TextureDescriptor{
            .label = wgpu.StringView.fromSlice("input_texture"),
            .size = wgpu.Extent3D{
                .width = limits.max_texture_dimension_2d / 2,
                .height = limits.max_texture_dimension_2d / 2,
                .depth_or_array_layers = 1,
            },
            .mip_level_count = 1,
            .sample_count = 1,
            .dimension = wgpu.TextureDimension.@"2d",
            .format = wgpu.TextureFormat.rgba16_float,
            .usage = wgpu.TextureUsages.storage_binding | wgpu.TextureUsages.texture_binding | wgpu.TextureUsages.copy_src | wgpu.TextureUsages.copy_dst,
        }).?;
        errdefer texture_a.release();

        const texture_b = gpu.device.createTexture(&wgpu.TextureDescriptor{
            .label = wgpu.StringView.fromSlice("output_texture"),
            .size = wgpu.Extent3D{
                .width = limits.max_texture_dimension_2d / 2,
                .height = limits.max_texture_dimension_2d / 2,
                .depth_or_array_layers = 1,
            },
            .mip_level_count = 1,
            .sample_count = 1,
            .dimension = wgpu.TextureDimension.@"2d",
            .format = wgpu.TextureFormat.rgba16_float,
            .usage = wgpu.TextureUsages.storage_binding | wgpu.TextureUsages.texture_binding | wgpu.TextureUsages.copy_src | wgpu.TextureUsages.copy_dst,
        }).?;
        errdefer texture_b.release();

        // The bind group contains the actual resources to bind to the pipeline.

        // Even when the buffers are individually dropped, wgpu will keep the bind group and buffers
        // alive until the bind group itself is dropped.
        const bind_group_entries_a_to_b = [_]wgpu.BindGroupEntry{
            // Binding 0: input storage buffer
            wgpu.BindGroupEntry{
                .binding = 0,
                .texture_view = texture_a.createView(null),
                .offset = 0,
                .size = texture_a.getWidth() * texture_a.getHeight() * 4, // width * height * RGBA
            },
            // Binding 1: output storage buffer
            wgpu.BindGroupEntry{
                .binding = 1,
                .texture_view = texture_b.createView(null),
                .offset = 0,
                .size = texture_b.getWidth() * texture_b.getHeight() * 4, // width * height * RGBA
            },
        };
        const bind_group_a_to_b = gpu.device.createBindGroup(&wgpu.BindGroupDescriptor{
            .label = wgpu.StringView.fromSlice("Bind Group 1"),
            .layout = bind_group_layout,
            .entry_count = 2,
            .entries = &bind_group_entries_a_to_b,
        }).?;
        errdefer bind_group_a_to_b.release();

        const bind_group_entries_b_to_a = [_]wgpu.BindGroupEntry{
            // Binding 0: output storage buffer
            wgpu.BindGroupEntry{
                .binding = 0,
                .texture_view = texture_b.createView(null),
                .offset = 0,
                .size = texture_b.getWidth() * texture_b.getHeight() * 4, // width * height * RGBA
            },
            // Binding 1: input storage buffer
            wgpu.BindGroupEntry{
                .binding = 1,
                .texture_view = texture_a.createView(null),
                .offset = 0,
                .size = texture_a.getWidth() * texture_a.getHeight() * 4, // width * height * RGBA
            },
        };
        const bind_group_b_to_a = gpu.device.createBindGroup(&wgpu.BindGroupDescriptor{
            .label = wgpu.StringView.fromSlice("Bind Group 2"),
            .layout = bind_group_layout,
            .entry_count = 2,
            .entries = &bind_group_entries_b_to_a,
        }).?;
        errdefer bind_group_b_to_a.release();

        // TODO: Cache the pipeline and layout for each shader module and entry point combination.
        // The pipeline layout describes the bind groups that a pipeline expects
        const bind_group_layouts = [_]*wgpu.BindGroupLayout{bind_group_layout};
        const pipeline_layout = gpu.device.createPipelineLayout(&wgpu.PipelineLayoutDescriptor{
            .label = wgpu.StringView.fromSlice("Pipeline Layout"),
            .bind_group_layout_count = 1,
            .bind_group_layouts = &bind_group_layouts,
        }).?;
        errdefer pipeline_layout.release();

        std.log.info("Compiling shader", .{});

        // Create the shader module from WGSL source code.
        // You can also load SPIR-V or use the Naga IR.
        const shader_module = gpu.device.createShaderModule(&wgpu.shaderModuleWGSLDescriptor(.{
            .label = "Compute Shader",
            .code = shader_source,
        })).?;
        errdefer shader_module.release();

        // The pipeline is the ready-to-go program state for the GPU. It contains the shader modules,
        // the interfaces (bind group layouts) and the shader entry point.
        const pipeline = gpu.device.createComputePipeline(&wgpu.ComputePipelineDescriptor{
            .label = wgpu.StringView.fromSlice("Compute Pipeline"),
            .layout = pipeline_layout,
            .compute = wgpu.ProgrammableStageDescriptor{
                .module = shader_module,
                .entry_point = wgpu.StringView.fromSlice(entry_point),
            },
        }).?;
        errdefer pipeline.release();

        return ShaderPipe{
            .textures = [_]*wgpu.Texture{ texture_a, texture_b },
            .bind_group_layout = bind_group_layout,
            .bind_groups = [2]*wgpu.BindGroup{ bind_group_a_to_b, bind_group_b_to_a },
            .shader_module = shader_module,
            .pipeline_layout = pipeline_layout,
            .pipeline = pipeline,
        };
    }

    pub fn deinit(self: *Self) void {
        std.log.info("Deinitializing ShaderPass", .{});

        self.textures[1].release();
        self.textures[0].release();
        self.bind_groups[1].release();
        self.bind_groups[0].release();
        self.bind_group_layout.release();

        self.shader_module.release();
        self.pipeline_layout.release();
        self.pipeline.release();
    }

    pub fn swapBuffers(self: *Self) void {
        self.is_swapped = !self.is_swapped;
    }

    pub fn getSrcIndex(self: *Self) usize {
        return if (self.is_swapped) 1 else 0;
    }
    pub fn getDstIndex(self: *Self) usize {
        return if (self.is_swapped) 0 else 1;
    }
    pub fn getSrcTexture(self: *Self) *wgpu.Texture {
        return self.textures[self.getSrcIndex()];
    }
    pub fn getDstTexture(self: *Self) *wgpu.Texture {
        return self.textures[self.getDstIndex()];
    }
    pub fn getCurrentBindGroup(self: *Self) *wgpu.BindGroup {
        return self.bind_groups[if (self.is_swapped) 1 else 0];
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
    // textures: [2]*wgpu.Texture = [_]*wgpu.Texture{ undefined, undefined },
    upload_buffer: *wgpu.Buffer = undefined,
    download_buffer: *wgpu.Buffer = undefined,
    // bind_group_layout: *wgpu.BindGroupLayout = undefined,
    // bind_groups: [2]*wgpu.BindGroup = [_]*wgpu.BindGroup{ undefined, undefined },
    encoder: *wgpu.CommandEncoder = undefined,
    // pipeline_layout: *wgpu.PipelineLayout = undefined,
    // is_swapped: bool = false,
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

        var max_buffer_size = limits.max_buffer_size;
        if (max_buffer_size == wgpu.WGPU_LIMIT_U64_UNDEFINED) {
            // set to something reasonable
            // max_buffer_size = 256 * 1024 * 1024; // 256 MB
            max_buffer_size = 256 * 1024 * 1024 * 12; // 3x256 MB for RGBAf16
        }

        // const texture_a = device.createTexture(&wgpu.TextureDescriptor{
        //     .label = wgpu.StringView.fromSlice("input_texture"),
        //     .size = wgpu.Extent3D{
        //         .width = limits.max_texture_dimension_2d / 2,
        //         .height = limits.max_texture_dimension_2d / 2,
        //         .depth_or_array_layers = 1,
        //     },
        //     .mip_level_count = 1,
        //     .sample_count = 1,
        //     .dimension = wgpu.TextureDimension.@"2d",
        //     .format = wgpu.TextureFormat.rgba16_float,
        //     .usage = wgpu.TextureUsages.storage_binding | wgpu.TextureUsages.texture_binding | wgpu.TextureUsages.copy_src | wgpu.TextureUsages.copy_dst,
        // }).?;
        // errdefer texture_a.release();

        // const texture_b = device.createTexture(&wgpu.TextureDescriptor{
        //     .label = wgpu.StringView.fromSlice("output_texture"),
        //     .size = wgpu.Extent3D{
        //         .width = limits.max_texture_dimension_2d / 2,
        //         .height = limits.max_texture_dimension_2d / 2,
        //         .depth_or_array_layers = 1,
        //     },
        //     .mip_level_count = 1,
        //     .sample_count = 1,
        //     .dimension = wgpu.TextureDimension.@"2d",
        //     .format = wgpu.TextureFormat.rgba16_float,
        //     .usage = wgpu.TextureUsages.storage_binding | wgpu.TextureUsages.texture_binding | wgpu.TextureUsages.copy_src | wgpu.TextureUsages.copy_dst,
        // }).?;

        // Finally we create a buffer which can be read by the CPU. This buffer is how we will read
        // the data. We need to use a separate buffer because we need to have a usage of `MAP_READ`,
        // and that usage can only be used with `COPY_DST`.
        // const buffer_size = WIDTH * WIDTH * BYTES_PER_PIXEL_RGBAf16;
        const upload_buffer = device.createBuffer(&wgpu.BufferDescriptor{
            .label = wgpu.StringView.fromSlice("upload_buffer"),
            .usage = wgpu.BufferUsages.copy_src | wgpu.BufferUsages.map_write,
            .size = max_buffer_size / 16,
            .mapped_at_creation = @as(u32, @intFromBool(true)),
        }).?;
        errdefer upload_buffer.release();
        const download_buffer = device.createBuffer(&wgpu.BufferDescriptor{
            .label = wgpu.StringView.fromSlice("download_buffer"),
            .usage = wgpu.BufferUsages.copy_dst | wgpu.BufferUsages.map_read,
            .size = max_buffer_size / 16,
            .mapped_at_creation = @as(u32, @intFromBool(false)),
        }).?;
        errdefer download_buffer.release();

        // // A bind group layout describes the types of resources that a bind group can contain. Think
        // // of this like a C-style header declaration, ensuring both the pipeline and bind group agree
        // // on the types of resources.
        // //
        // // Note, we are using a texture in binding 0 and a storage texture in binding 1.
        // // this is because readable storage textures are not supported in WebGPU unless you enable
        // // (readonly_and_readwrite_storage_textures).
        // // This is also done in vkdt
        // //
        // // TODO: create multiple bind groups/layouts for different shader needs and oversized buffers
        // const bind_group_layout_entries = &[_]wgpu.BindGroupLayoutEntry{
        //     // Binding 0: input storage buffer
        //     wgpu.BindGroupLayoutEntry{
        //         .binding = 0,
        //         .visibility = wgpu.ShaderStages.compute,
        //         .texture = wgpu.TextureBindingLayout{
        //             .view_dimension = wgpu.ViewDimension.@"2d",
        //         },
        //     },
        //     // Binding 1: output storage buffer
        //     wgpu.BindGroupLayoutEntry{
        //         .binding = 1,
        //         .visibility = wgpu.ShaderStages.compute,
        //         // .buffer = wgpu.BufferBindingLayout{
        //         //     .type = wgpu.BufferBindingType.storage,
        //         //     .has_dynamic_offset = @as(u32, @intFromBool(false)),
        //         // },
        //         // .texture = wgpu.TextureBindingLayout{
        //         //     // .sample_type = wgpu.SampleType.float,
        //         //     .view_dimension = wgpu.ViewDimension.@"2d",
        //         //     // .multisampled = @as(u32, @intFromBool(false)),
        //         // },
        //         .storage_texture = wgpu.StorageTextureBindingLayout{
        //             .access = wgpu.StorageTextureAccess.write_only,
        //             .format = wgpu.TextureFormat.rgba16_float,
        //             .view_dimension = wgpu.ViewDimension.@"2d",
        //         },
        //     },
        // };
        // const bind_group_layout = device.createBindGroupLayout(&wgpu.BindGroupLayoutDescriptor{
        //     .label = wgpu.StringView.fromSlice("Bind Group Layout"),
        //     .entry_count = 2,
        //     .entries = bind_group_layout_entries,
        // }).?;

        // The bind group contains the actual resources to bind to the pipeline.
        //
        // Even when the buffers are individually dropped, wgpu will keep the bind group and buffers
        // alive until the bind group itself is dropped.
        // const bind_group_entries_a_to_b = [_]wgpu.BindGroupEntry{
        //     // Binding 0: input storage buffer
        //     wgpu.BindGroupEntry{
        //         .binding = 0,
        //         .texture_view = texture_a.createView(null),
        //         .offset = 0,
        //         .size = texture_a.getWidth() * texture_a.getHeight() * 4, // width * height * RGBA
        //     },
        //     // Binding 1: output storage buffer
        //     wgpu.BindGroupEntry{
        //         .binding = 1,
        //         .texture_view = texture_b.createView(null),
        //         .offset = 0,
        //         .size = texture_b.getWidth() * texture_b.getHeight() * 4, // width * height * RGBA
        //     },
        // };
        // const bind_group_a_to_b = device.createBindGroup(&wgpu.BindGroupDescriptor{
        //     .label = wgpu.StringView.fromSlice("Bind Group 1"),
        //     .layout = bind_group_layout,
        //     .entry_count = 2,
        //     .entries = &bind_group_entries_a_to_b,
        // }).?;
        // errdefer bind_group_a_to_b.release();

        // const bind_group_entries_b_to_a = [_]wgpu.BindGroupEntry{
        //     // Binding 0: output storage buffer
        //     wgpu.BindGroupEntry{
        //         .binding = 0,
        //         .texture_view = texture_b.createView(null),
        //         .offset = 0,
        //         .size = texture_b.getWidth() * texture_b.getHeight() * 4, // width * height * RGBA
        //     },
        //     // Binding 1: input storage buffer
        //     wgpu.BindGroupEntry{
        //         .binding = 1,
        //         .texture_view = texture_a.createView(null),
        //         .offset = 0,
        //         .size = texture_a.getWidth() * texture_a.getHeight() * 4, // width * height * RGBA
        //     },
        // };
        // const bind_group_b_to_a = device.createBindGroup(&wgpu.BindGroupDescriptor{
        //     .label = wgpu.StringView.fromSlice("Bind Group 2"),
        //     .layout = bind_group_layout,
        //     .entry_count = 2,
        //     .entries = &bind_group_entries_b_to_a,
        // }).?;
        // errdefer bind_group_b_to_a.release();

        // The command encoder allows us to record commands that we will later submit to the GPU.
        const encoder = device.createCommandEncoder(&wgpu.CommandEncoderDescriptor{
            .label = wgpu.StringView.fromSlice("Command Encoder"),
        }).?;
        errdefer encoder.release();

        // // TODO: Cache the pipeline and layout for each shader module and entry point combination.
        // // The pipeline layout describes the bind groups that a pipeline expects
        // const bind_group_layouts = [_]*wgpu.BindGroupLayout{bind_group_layout};
        // const pipeline_layout = device.createPipelineLayout(&wgpu.PipelineLayoutDescriptor{
        //     .label = wgpu.StringView.fromSlice("Pipeline Layout"),
        //     .bind_group_layout_count = 1,
        //     .bind_group_layouts = &bind_group_layouts,
        // }).?;

        return Self{
            .instance = instance,
            .adapter = adapter,
            .device = device,
            .queue = queue,
            // .is_swapped = false,
            // .textures = [_]*wgpu.Texture{ texture_a, texture_b },
            .upload_buffer = upload_buffer,
            .download_buffer = download_buffer,
            // .bind_groups = [2]*wgpu.BindGroup{ bind_group_a_to_b, bind_group_b_to_a },
            // .bind_group_layout = bind_group_layout,
            .encoder = encoder,
            // .pipeline_layout = pipeline_layout,
            .adapter_name = info.device.toSlice() orelse "Unknown",
        };
    }

    pub fn deinit(self: *Self) void {
        std.log.info("Deinitializing GPU", .{});

        // self.pipeline_layout.release();
        self.encoder.release();
        // self.bind_group_layout.release();
        // self.bind_groups[1].release();
        // self.bind_groups[0].release();
        self.download_buffer.release();
        self.upload_buffer.release();

        // self.textures[0].release();
        // self.textures[1].release();

        self.queue.release();
        self.device.release();
        self.adapter.release();
        self.instance.release();
    }

    pub fn enqueueShader(self: *Self, shader_pipe: *ShaderPipe, region: CopyRegionParams) void {
        std.log.info("Running compute shader", .{});

        std.log.info("Dispatching compute work", .{});
        // A compute pass is a single series of compute operations. While we are recording a compute
        // pass, we cannot record to the encoder.
        const compute_pass = self.encoder.beginComputePass(&wgpu.ComputePassDescriptor{
            .label = wgpu.StringView.fromSlice("Compute Pass"),
        }).?;
        // Set the pipeline that we want to use
        compute_pass.setPipeline(shader_pipe.pipeline);
        compute_pass.setBindGroup(0, shader_pipe.getCurrentBindGroup(), 0, null);

        // Now we dispatch a series of workgroups. Each workgroup is a 3D grid of individual programs.
        //
        // If the user passes 32 inputs, we will
        // dispatch 1 workgroups. If the user passes 65 inputs, we will dispatch 2 workgroups, etc.
        const output_size = region.w * region.h;
        const workgroup_size = WORKGROUP_SIZE_X * WORKGROUP_SIZE_Y * WORKGROUP_SIZE_Z;
        const workgroup_count_x = (region.w + WORKGROUP_SIZE_X - 1) / WORKGROUP_SIZE_X;
        const workgroup_count_y = (region.h + WORKGROUP_SIZE_Y - 1) / WORKGROUP_SIZE_Y;
        const workgroup_count_z = 1;
        std.log.info("output_size: {d}", .{output_size});
        std.log.info("workgroup_size: {d}", .{workgroup_size});
        std.log.info("workgroup_count_x: {d}", .{workgroup_count_x});
        std.log.info("workgroup_count_y: {d}", .{workgroup_count_y});
        std.log.info("workgroup_count_z: {d}", .{workgroup_count_z});
        std.log.info("total workgroups: {d}", .{workgroup_count_x * workgroup_count_y * workgroup_count_z});
        std.log.info("total invocations: {d}", .{@as(u32, workgroup_count_x) * workgroup_count_y * workgroup_count_z * workgroup_size});

        compute_pass.dispatchWorkgroups(workgroup_count_x, workgroup_count_y, workgroup_count_z);
        // Now we drop the compute pass, giving us access to the encoder again.
        compute_pass.end();
    }

    pub fn enqueueStage(self: *Self, shader_pipe: *ShaderPipe, region: CopyRegionParams, ox: u32, oy: u32) !void {
        std.log.info("Writing GPU buffer to Shader Buffer", .{});

        // check bytes_per_row is a multiple of 256
        const bytes_per_row = region.w * BYTES_PER_PIXEL_RGBAf16;
        if (bytes_per_row % 256 != 0) {
            std.log.err("bytes_per_row must be a multiple of 256, got {d}", .{bytes_per_row});
            return error.InvalidInput;
        }

        // We add a copy operation to the encoder. This will copy the data from the upload buffer on the
        // CPU to the input buffer on the GPU.
        // self.encoder.copyBufferToBuffer(self.upload_buffer, 0, self.buffer[self.src_index], 0, self.buffer[self.src_index].getSize());
        // const copy_size = self.textures[self.src_index].getWidth() * self.textures[self.src_index].getHeight() * 4; // width * height * RGBA
        const copy_size = wgpu.Extent3D{
            .width = region.w,
            .height = region.h,
            .depth_or_array_layers = 1,
        };
        std.log.info("[enqueueStage] copy_size.width: {d}", .{copy_size.width});
        std.log.info("[enqueueStage] copy_size.height: {d}", .{copy_size.height});
        std.log.info("[enqueueStage] copy_size.depth_or_array_layers: {d}", .{copy_size.depth_or_array_layers});
        const offset = @as(u64, oy) * region.w * BYTES_PER_PIXEL_RGBAf16 + ox * BYTES_PER_PIXEL_RGBAf16;
        std.log.info("[enqueueStage] offset: {d}", .{offset});
        const source = wgpu.TexelCopyBufferInfo{
            .buffer = self.upload_buffer,
            .layout = wgpu.TexelCopyBufferLayout{
                // .offset = 0,
                .offset = offset,
                .bytes_per_row = region.w * BYTES_PER_PIXEL_RGBAf16, // width * RGBA
                .rows_per_image = region.h,
            },
        };
        std.log.info("[enqueueStage] source.buffer size: {d}", .{self.upload_buffer.getSize()});
        std.log.info("[enqueueStage] source.layout.bytes_per_row: {d}", .{source.layout.bytes_per_row});
        std.log.info("[enqueueStage] source.layout.rows_per_image: {d}", .{source.layout.rows_per_image});
        const destination = wgpu.TexelCopyTextureInfo{
            .texture = shader_pipe.getSrcTexture(), //self.textures[self.get_src_index()],
            .mip_level = 0,
            .origin = wgpu.Origin3D{ .x = ox, .y = oy, .z = 0 },
        };
        self.encoder.copyBufferToTexture(&source, &destination, &copy_size);
    }
    pub fn enqueueDestage(self: *Self, shader_pipe: *ShaderPipe, region: CopyRegionParams, ox: u32, oy: u32) !void {
        std.log.info("Reading GPU buffer from Shader Buffer", .{});

        // check bytes_per_row is a multiple of 256
        const bytes_per_row = region.w * BYTES_PER_PIXEL_RGBAf16;
        if (bytes_per_row % 256 != 0) {
            std.log.err("bytes_per_row must be a multiple of 256, got {d}", .{bytes_per_row});
            return error.InvalidInput;
        }

        // We add a copy operation to the encoder. This will copy the data from the output buffer on the
        // GPU to the download buffer on the CPU.
        // self.encoder.copyBufferToBuffer(self.buffer[self.dst_index], 0, self.download_buffer, 0, self.buffer[self.dst_index].getSize());
        // const copy_size = self.textures[self.dst_index].getWidth() * self.textures[self.dst_index].getHeight() * 4; // width * height * RGBA
        const copy_size = wgpu.Extent3D{
            .width = region.w,
            .height = region.h,
            .depth_or_array_layers = 1,
        };
        std.log.info("[enqueueDestage] copy_size.width: {d}", .{copy_size.width});
        std.log.info("[enqueueDestage] copy_size.height: {d}", .{copy_size.height});
        std.log.info("[enqueueDestage] copy_size.depth_or_array_layers: {d}", .{copy_size.depth_or_array_layers});
        const source = wgpu.TexelCopyTextureInfo{
            .texture = shader_pipe.getDstTexture(), // self.textures[self.get_dst_index()],
            .mip_level = 0,
            // .origin = wgpu.Origin3D{ .x = 0, .y = 0, .z = 0 },
            .origin = wgpu.Origin3D{ .x = ox, .y = oy, .z = 0 },
        };
        const offset = @as(u64, oy) * region.w * BYTES_PER_PIXEL_RGBAf16 + ox * BYTES_PER_PIXEL_RGBAf16;
        std.log.info("[enqueueDestage] offset: {d}", .{offset});
        const destination = wgpu.TexelCopyBufferInfo{
            .buffer = self.download_buffer,
            .layout = wgpu.TexelCopyBufferLayout{
                // .offset = 0,
                .offset = offset,
                .bytes_per_row = region.w * BYTES_PER_PIXEL_RGBAf16, // width * RGBA
                .rows_per_image = region.h,
            },
        };
        std.log.info("[enqueueDestage] destination.buffer size: {d}", .{self.download_buffer.getSize()});
        std.log.info("[enqueueDestage] destination.layout.bytes_per_row: {d}", .{destination.layout.bytes_per_row});
        std.log.info("[enqueueDestage] destination.layout.rows_per_image: {d}", .{destination.layout.rows_per_image});
        self.encoder.copyTextureToBuffer(&source, &destination, &copy_size);
    }

    pub fn run(self: *Self) void {
        std.log.info("Submitting command buffer to GPU", .{});

        // We finish the encoder, giving us a fully recorded command buffer.
        const command_buffer = self.encoder.finish(&wgpu.CommandBufferDescriptor{
            .label = wgpu.StringView.fromSlice("Command Buffer"),
        }).?;
        defer command_buffer.release();

        // At this point nothing has actually been executed on the gpu. We have recorded a series of
        // commands that we want to execute, but they haven't been sent to the gpu yet.
        //
        // Submitting to the queue sends the command buffer to the gpu. The gpu will then execute the
        // commands in the command buffer in order.
        self.queue.submit(&[_]*const wgpu.CommandBuffer{command_buffer});
    }

    pub fn mapUpload(self: *Self, data: []const f16, region: CopyRegionParams) void {
        std.log.info("Writing data to GPU buffers", .{});

        const size = region.w * region.h * BYTES_PER_PIXEL_RGBAf16;
        const upload_buffer_ptr: [*]f16 = @ptrCast(@alignCast(self.upload_buffer.getMappedRange(0, size).?));
        defer self.upload_buffer.unmap();
        @memcpy(upload_buffer_ptr, data);
    }
    pub fn mapDownload(self: *Self, region: CopyRegionParams) ![]f16 {
        std.log.info("Reading data from GPU buffers", .{});

        const size = region.w * region.h * BYTES_PER_PIXEL_RGBAf16;

        // We now map the download buffer so we can read it. Mapping tells wgpu that we want to read/write
        // to the buffer directly by the CPU and it should not permit any more GPU operations on the buffer.
        //
        // Mapping requires that the GPU be finished using the buffer before it resolves, so mapping has a callback
        // to tell you when the mapping is complete.
        var buffer_map_complete = false;
        _ = self.download_buffer.mapAsync(wgpu.MapModes.read, 0, size, wgpu.BufferMapCallbackInfo{
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
        const download_buffer_ptr: [*]f16 = @ptrCast(@alignCast(self.download_buffer.getMappedRange(0, size).?));
        defer self.download_buffer.unmap();

        const result = download_buffer_ptr[0..size];
        return result;
    }
};
