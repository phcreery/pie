const std = @import("std");
const wgpu = @import("wgpu");

const COPY_BUFFER_ALIGNMENT: u64 = 4; // https://github.com/gfx-rs/wgpu/blob/trunk/wgpu-types/src/lib.rs#L96

const output_size = 4;
const init_contents: [output_size]f32 = [_]f32{ 1, 2, 3, 4 };
const unpadded_size = @sizeOf(@TypeOf(init_contents));
// Valid vulkan usage is
// 1. buffer size must be a multiple of COPY_BUFFER_ALIGNMENT.
// 2. buffer size must be greater than 0.
// Therefore we round the value up to the nearest multiple, and ensure it's at least COPY_BUFFER_ALIGNMENT.
const align_mask = COPY_BUFFER_ALIGNMENT - 1;
const padded_size = @max((unpadded_size + align_mask) & ~align_mask, COPY_BUFFER_ALIGNMENT);
// std.debug.print("unpadded_size: {d}, padded_size: {d}\n", .{ unpadded_size, padded_size });

fn handleBufferMap(status: wgpu.MapAsyncStatus, _: wgpu.StringView, userdata1: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    std.log.info("buffer_map status={x:.8}\n", .{@intFromEnum(status)});
    const complete: *bool = @ptrCast(@alignCast(userdata1));
    complete.* = true;
}

pub const ShaderPipe = struct {
    shader_module: *wgpu.ShaderModule,
    pipeline: *wgpu.ComputePipeline,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        std.log.info("Deinitializing ShaderPass", .{});

        self.shader_module.release();
        self.pipeline.release();
    }
};

/// Engine manages the WebGPU instance, adapter, device, and queue.
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
pub const Engine = struct {
    instance: *wgpu.Instance = undefined,
    adapter: *wgpu.Adapter = undefined,
    device: *wgpu.Device = undefined,
    queue: *wgpu.Queue = undefined,
    buffer: [2]*wgpu.Buffer = [_]*wgpu.Buffer{ undefined, undefined },
    download_buffer: *wgpu.Buffer = undefined,
    bind_group: [2]*wgpu.BindGroup = [_]*wgpu.BindGroup{ undefined, undefined },
    bind_group_layout: *wgpu.BindGroupLayout = undefined,
    encoder: *wgpu.CommandEncoder = undefined,
    pipeline_layout: *wgpu.PipelineLayout = undefined,

    src_index: usize = 0,
    dst_index: usize = 1,
    // is_swapped: bool = false,

    const Self = @This();

    pub fn init() !Self {
        std.log.info("Initializing Engine", .{});

        const instance = wgpu.Instance.create(null).?;
        errdefer instance.release();

        const adapter_request = instance.requestAdapterSync(&wgpu.RequestAdapterOptions{}, 0);
        const adapter = switch (adapter_request.status) {
            .success => adapter_request.adapter.?,
            else => return error.NoAdapter,
        };
        errdefer adapter.release();

        // We then create a `Device` and a `Queue` from the `Adapter`.
        const device_request = adapter.requestDeviceSync(instance, &wgpu.DeviceDescriptor{
            .required_limits = null,
        }, 0);
        const device = switch (device_request.status) {
            .success => device_request.device.?,
            else => return error.NoDevice,
        };
        errdefer device.release();

        const queue = device.getQueue().?;
        errdefer queue.release();

        const buffer_a = device.createBuffer(&wgpu.BufferDescriptor{
            .label = wgpu.StringView.fromSlice("input_storage_buffer"),
            .usage = wgpu.BufferUsages.storage | wgpu.BufferUsages.copy_src,
            .size = padded_size,
            .mapped_at_creation = @as(f32, @intFromBool(true)),
        }).?;
        errdefer buffer_a.release();

        // Now we create a buffer to store the output data. Same size and usage as the input buffer.
        const buffer_b = device.createBuffer(&wgpu.BufferDescriptor{
            .label = wgpu.StringView.fromSlice("output_storage_buffer"),
            .usage = wgpu.BufferUsages.storage | wgpu.BufferUsages.copy_src,
            .size = buffer_a.getSize(),
            .mapped_at_creation = @as(u32, @intFromBool(false)),
        }).?;

        // Finally we create a buffer which can be read by the CPU. This buffer is how we will read
        // the data. We need to use a separate buffer because we need to have a usage of `MAP_READ`,
        // and that usage can only be used with `COPY_DST`.
        const download_storage_buffer = device.createBuffer(&wgpu.BufferDescriptor{
            .label = wgpu.StringView.fromSlice("download_storage_buffer"),
            .usage = wgpu.BufferUsages.map_read | wgpu.BufferUsages.copy_dst,
            .size = buffer_a.getSize(),
            .mapped_at_creation = @as(u32, @intFromBool(false)),
        }).?;
        errdefer download_storage_buffer.release();

        // A bind group layout describes the types of resources that a bind group can contain. Think
        // of this like a C-style header declaration, ensuring both the pipeline and bind group agree
        // on the types of resources.
        const bind_group_layout_entry = &[_]wgpu.BindGroupLayoutEntry{
            // Binding 0: input storage buffer
            wgpu.BindGroupLayoutEntry{
                .binding = 0,
                .visibility = wgpu.ShaderStages.compute,
                .buffer = wgpu.BufferBindingLayout{
                    .type = wgpu.BufferBindingType.read_only_storage,
                    .has_dynamic_offset = @as(u32, @intFromBool(false)),
                },
            },
            // Binding 1: output storage buffer
            wgpu.BindGroupLayoutEntry{
                .binding = 1,
                .visibility = wgpu.ShaderStages.compute,
                .buffer = wgpu.BufferBindingLayout{
                    .type = wgpu.BufferBindingType.storage,
                    .has_dynamic_offset = @as(u32, @intFromBool(false)),
                },
            },
        };
        const bind_group_layout = device.createBindGroupLayout(&wgpu.BindGroupLayoutDescriptor{
            .label = wgpu.StringView.fromSlice("Bind Group Layout"),
            .entry_count = 2,
            .entries = bind_group_layout_entry,
        }).?;

        // The bind group contains the actual resources to bind to the pipeline.
        //
        // Even when the buffers are individually dropped, wgpu will keep the bind group and buffers
        // alive until the bind group itself is dropped.
        const bind_group_entries_a_to_b = [_]wgpu.BindGroupEntry{
            // Binding 0: input storage buffer
            wgpu.BindGroupEntry{
                .binding = 0,
                .buffer = buffer_a,
                .offset = 0,
                .size = buffer_a.getSize(),
            },
            // Binding 1: output storage buffer
            wgpu.BindGroupEntry{
                .binding = 1,
                .buffer = buffer_b,
                .offset = 0,
                .size = buffer_b.getSize(),
            },
        };
        const bind_group_a_to_b = device.createBindGroup(&wgpu.BindGroupDescriptor{
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
                .buffer = buffer_b,
                .offset = 0,
                .size = buffer_b.getSize(),
            },
            // Binding 1: input storage buffer
            wgpu.BindGroupEntry{
                .binding = 1,
                .buffer = buffer_a,
                .offset = 0,
                .size = buffer_a.getSize(),
            },
        };
        const bind_group_b_to_a = device.createBindGroup(&wgpu.BindGroupDescriptor{
            .label = wgpu.StringView.fromSlice("Bind Group 2"),
            .layout = bind_group_layout,
            .entry_count = 2,
            .entries = &bind_group_entries_b_to_a,
        }).?;
        errdefer bind_group_b_to_a.release();

        // The command encoder allows us to record commands that we will later submit to the GPU.
        const encoder = device.createCommandEncoder(&wgpu.CommandEncoderDescriptor{
            .label = wgpu.StringView.fromSlice("Command Encoder"),
        }).?;
        errdefer encoder.release();

        // TODO: Cache the pipeline and layout for each shader module and entry point combination.
        // The pipeline layout describes the bind groups that a pipeline expects
        const bind_group_layouts = [_]*wgpu.BindGroupLayout{bind_group_layout};
        const pipeline_layout = device.createPipelineLayout(&wgpu.PipelineLayoutDescriptor{
            .label = wgpu.StringView.fromSlice("Pipeline Layout"),
            .bind_group_layout_count = 1,
            .bind_group_layouts = &bind_group_layouts,
        }).?;

        return Self{
            .instance = instance,
            .adapter = adapter,
            .device = device,
            .queue = queue,
            .src_index = 0,
            .dst_index = 1,
            .buffer = [_]*wgpu.Buffer{ buffer_a, buffer_b },
            .download_buffer = download_storage_buffer,
            .bind_group = [2]*wgpu.BindGroup{ bind_group_a_to_b, bind_group_b_to_a },
            .bind_group_layout = bind_group_layout,
            .encoder = encoder,
            .pipeline_layout = pipeline_layout,
        };
    }

    pub fn deinit(self: *Self) void {
        std.log.info("Deinitializing Engine", .{});

        self.instance.release();
        self.adapter.release();
        self.device.release();
        self.queue.release();

        self.buffer[0].release();
        self.buffer[1].release();
        self.download_buffer.release();
        self.bind_group[0].release();
        self.bind_group[1].release();
        self.bind_group_layout.release();
        self.encoder.release();
    }

    pub fn swapBuffers(self: *Self) void {
        self.src_index = 1 - self.src_index;
        self.dst_index = 1 - self.dst_index;

        // check that the buffers are swapped
        // std.debug.assert(self.src_index > 0 and self.src_index < 2);
        // std.debug.assert(self.dst_index > 0 and self.dst_index < 2);
        // std.debug.assert(self.src_index != self.dst_index);
    }

    pub fn compileShader(self: *Self, shader_source: []const u8, entry_point: []const u8) !ShaderPipe {
        std.log.info("Compiling shader", .{});

        // Create the shader module from WGSL source code.
        // You can also load SPIR-V or use the Naga IR.
        const shader_module = self.device.createShaderModule(&wgpu.shaderModuleWGSLDescriptor(.{
            .code = shader_source, // @embedFile("./shader2.wgsl"),
        })).?;
        // defer shader_module.release();
        // return shader_module;

        // The pipeline is the ready-to-go program state for the GPU. It contains the shader modules,
        // the interfaces (bind group layouts) and the shader entry point.
        const pipeline = self.device.createComputePipeline(&wgpu.ComputePipelineDescriptor{
            .label = wgpu.StringView.fromSlice("Compute Pipeline"),
            .layout = self.pipeline_layout,
            .compute = wgpu.ProgrammableStageDescriptor{
                .module = shader_module,
                .entry_point = wgpu.StringView.fromSlice(entry_point),
            },
        }).?;
        // defer pipeline.release();

        // return pipeline;
        return ShaderPipe{
            .shader_module = shader_module,
            .pipeline = pipeline,
        };
    }

    pub fn enqueue(self: *Self, shader_pass: ShaderPipe) void {
        std.log.info("Running compute shader", .{});

        std.log.info("Dispatching compute work", .{});
        // A compute pass is a single series of compute operations. While we are recording a compute
        // pass, we cannot record to the encoder.
        const compute_pass = self.encoder.beginComputePass(&wgpu.ComputePassDescriptor{
            .label = wgpu.StringView.fromSlice("Compute Pass"),
        }).?;
        // Set the pipeline that we want to use
        compute_pass.setPipeline(shader_pass.pipeline);
        compute_pass.setBindGroup(0, self.bind_group[self.src_index], 0, null);

        // Now we dispatch a series of workgroups. Each workgroup is a 3D grid of individual programs.
        //
        // We defined the workgroup size in the shader as 64x1x1. So in order to process all of our
        // inputs, we ceiling divide the number of inputs by 64. If the user passes 32 inputs, we will
        // dispatch 1 workgroups. If the user passes 65 inputs, we will dispatch 2 workgroups, etc.
        const workgroup_size = 64;
        const workgroup_count_x = (output_size + workgroup_size - 1) / workgroup_size;
        const workgroup_count_y = 1;
        const workgroup_count_z = 1;
        // std.debug.print("workgroup_count_x: {d}\n", .{workgroup_count_x});
        // std.debug.print("workgroup_count_y: {d}\n", .{workgroup_count_y});
        // std.debug.print("workgroup_count_z: {d}\n", .{workgroup_count_z});
        compute_pass.dispatchWorkgroups(workgroup_count_x, workgroup_count_y, workgroup_count_z);
        // Now we drop the compute pass, giving us access to the encoder again.
        compute_pass.end();
    }

    pub fn enqueueDownload(self: *Self) void {
        // We add a copy operation to the encoder. This will copy the data from the output buffer on the
        // GPU to the download buffer on the CPU.
        self.encoder.copyBufferToBuffer(self.buffer[self.dst_index], 0, self.download_buffer, 0, self.buffer[self.dst_index].getSize());
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

        // We now map the download buffer so we can read it. Mapping tells wgpu that we want to read/write
        // to the buffer directly by the CPU and it should not permit any more GPU operations on the buffer.
        //
        // Mapping requires that the GPU be finished using the buffer before it resolves, so mapping has a callback
        // to tell you when the mapping is complete.
        var buffer_map_complete = false;
        _ = self.download_buffer.mapAsync(wgpu.MapModes.read, 0, output_size, wgpu.BufferMapCallbackInfo{
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

    }

    pub fn upload(self: *Self, data: []const f32) void {
        std.log.info("Writing data to GPU buffers", .{});

        // write to write buffer
        const write_buffer_ptr: [*]f32 = @ptrCast(@alignCast(self.buffer[self.src_index].getMappedRange(0, padded_size).?));
        @memcpy(write_buffer_ptr, data);
        self.buffer[self.src_index].unmap();
    }
    pub fn download(self: *Self) ![]f32 {
        std.log.info("Reading data from GPU buffers", .{});

        // We can now read the data from the buffer.
        // Convert the data back to a slice of f32.
        const download_buffer_ptr: [*]f32 = @ptrCast(@alignCast(self.download_buffer.getMappedRange(0, output_size).?));
        defer self.download_buffer.unmap();

        // const result: [output_size]f32 = undefined;
        // @memcpy(result[0..], download_buffer_ptr);

        const result = download_buffer_ptr[0..output_size];
        return result;
    }
};
