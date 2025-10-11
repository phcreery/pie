// Based off of headless triangle example from https://github.com/eliemichel/LearnWebGPU-Code/tree/step030-headless
// and https://github.com/gfx-rs/wgpu/blob/trunk/examples/standalone/01_hello_compute/src/main.rs

const std = @import("std");
const wgpu = @import("wgpu");
const wgpuc = @import("wgpu-c");

const COPY_BUFFER_ALIGNMENT: u64 = 4; // https://github.com/gfx-rs/wgpu/blob/trunk/wgpu-types/src/lib.rs#L96
const output_size = 4;

fn handleBufferMap(status: wgpu.MapAsyncStatus, _: wgpu.StringView, userdata1: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    std.log.info("buffer_map status={x:.8}\n", .{@intFromEnum(status)});
    const complete: *bool = @ptrCast(@alignCast(userdata1));
    complete.* = true;
}

pub fn main() !void {
    const instance = wgpu.Instance.create(null).?;
    defer instance.release();

    const adapter_request = instance.requestAdapterSync(&wgpu.RequestAdapterOptions{}, 0);
    const adapter = switch (adapter_request.status) {
        .success => adapter_request.adapter.?,
        else => return error.NoAdapter,
    };
    defer adapter.release();

    var info: wgpu.AdapterInfo = undefined;
    const status = adapter.getInfo(&info);
    if (status != .success) {
        std.log.info("Failed to get adapter info", .{});
        return error.AdapterInfo;
    } else {
        const name = info.device.toSlice();
        if (name) |value| {
            std.log.info("Using adapter: {s} (backend={any})", .{ value, @intFromEnum(info.backend_type) });
        } else {
            std.log.info("Failed to get adapter name", .{});
        }
    }

    // We then create a `Device` and a `Queue` from the `Adapter`.
    const device_request = adapter.requestDeviceSync(instance, &wgpu.DeviceDescriptor{
        .required_limits = null,
    }, 0);
    const device = switch (device_request.status) {
        .success => device_request.device.?,
        else => return error.NoDevice,
    };
    defer device.release();

    const queue = device.getQueue().?;
    defer queue.release();

    // Create the shader module from WGSL source code.
    // You can also load SPIR-V or use the Naga IR.
    const shader_module = device.createShaderModule(&wgpu.shaderModuleWGSLDescriptor(.{
        .code = @embedFile("./shader2.wgsl"),
    })).?;
    defer shader_module.release();

    const init_contents: [output_size]f32 = [_]f32{ 1, 2, 3, 4 };
    const unpadded_size = @sizeOf(@TypeOf(init_contents));
    const align_mask = COPY_BUFFER_ALIGNMENT - 1;
    const padded_size = (unpadded_size + align_mask) & ~align_mask;
    std.debug.print("unpadded_size: {d}, padded_size: {d}\n", .{ unpadded_size, padded_size });

    // Create a for the data we want to process on the GPU.
    const input_storage_buffer = device.createBuffer(&wgpu.BufferDescriptor{
        .label = wgpu.StringView.fromSlice("input_storage_buffer"),
        .usage = wgpu.BufferUsages.storage,
        .size = padded_size,
        .mapped_at_creation = @as(f32, @intFromBool(true)),
    }).?;
    defer input_storage_buffer.release();

    // Write the input data to the buffer.
    const buf_ptr: [*]f32 = @ptrCast(@alignCast(input_storage_buffer.getMappedRange(0, padded_size).?));
    // std.mem.copyForwards(u32, buf_ptr, init_contents[0..unpadded_size]);
    @memcpy(buf_ptr, &init_contents);
    input_storage_buffer.unmap();

    // Now we create a buffer to store the output data.
    const output_storage_buffer = device.createBuffer(&wgpu.BufferDescriptor{
        .label = wgpu.StringView.fromSlice("output_storage_buffer"),
        .usage = wgpu.BufferUsages.storage | wgpu.BufferUsages.copy_src,
        .size = input_storage_buffer.getSize(),
        .mapped_at_creation = @as(u32, @intFromBool(false)),
    }).?;

    // Finally we create a buffer which can be read by the CPU. This buffer is how we will read
    // the data. We need to use a separate buffer because we need to have a usage of `MAP_READ`,
    // and that usage can only be used with `COPY_DST`.
    const download_storage_buffer = device.createBuffer(&wgpu.BufferDescriptor{
        .label = wgpu.StringView.fromSlice("download_storage_buffer"),
        .usage = wgpu.BufferUsages.map_read | wgpu.BufferUsages.copy_dst,
        .size = input_storage_buffer.getSize(),
        .mapped_at_creation = @as(u32, @intFromBool(false)),
    }).?;
    defer download_storage_buffer.release();

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
    const bind_group_entries = [_]wgpu.BindGroupEntry{
        // Binding 0: input storage buffer
        wgpu.BindGroupEntry{
            .binding = 0,
            .buffer = input_storage_buffer,
            .offset = 0,
            .size = input_storage_buffer.getSize(),
        },
        // Binding 1: output storage buffer
        wgpu.BindGroupEntry{
            .binding = 1,
            .buffer = output_storage_buffer,
            .offset = 0,
            .size = output_storage_buffer.getSize(),
        },
    };
    const bind_group = device.createBindGroup(&wgpu.BindGroupDescriptor{
        .label = wgpu.StringView.fromSlice("Bind Group"),
        .layout = bind_group_layout,
        .entry_count = 2,
        .entries = &bind_group_entries,
    }).?;
    defer bind_group.release();

    // The pipeline layout describes the bind groups that a pipeline expects
    const bind_group_layouts = [_]*wgpu.BindGroupLayout{bind_group_layout};
    const pipeline_layout = device.createPipelineLayout(&wgpu.PipelineLayoutDescriptor{
        .label = wgpu.StringView.fromSlice("Pipeline Layout"),
        .bind_group_layout_count = 1,
        .bind_group_layouts = &bind_group_layouts,
    }).?;

    // The pipeline is the ready-to-go program state for the GPU. It contains the shader modules,
    // the interfaces (bind group layouts) and the shader entry point.
    const pipeline = device.createComputePipeline(&wgpu.ComputePipelineDescriptor{
        .label = wgpu.StringView.fromSlice("Compute Pipeline"),
        .layout = pipeline_layout,
        .compute = wgpu.ProgrammableStageDescriptor{
            .module = shader_module,
            .entry_point = wgpu.StringView.fromSlice("doubleMe"),
        },
    }).?;
    defer pipeline.release();

    { // Mock main "loop"

        // The command encoder allows us to record commands that we will later submit to the GPU.
        const encoder = device.createCommandEncoder(&wgpu.CommandEncoderDescriptor{
            .label = wgpu.StringView.fromSlice("Command Encoder"),
        }).?;
        defer encoder.release();

        // A compute pass is a single series of compute operations. While we are recording a compute
        // pass, we cannot record to the encoder.
        const compute_pass = encoder.beginComputePass(&wgpu.ComputePassDescriptor{
            .label = wgpu.StringView.fromSlice("Compute Pass"),
        }).?;
        // Set the pipeline that we want to use
        compute_pass.setPipeline(pipeline);
        // Set the bind group that we want to use
        compute_pass.setBindGroup(0, bind_group, 0, null);

        // Now we dispatch a series of workgroups. Each workgroup is a 3D grid of individual programs.
        //
        // We defined the workgroup size in the shader as 64x1x1. So in order to process all of our
        // inputs, we ceiling divide the number of inputs by 64. If the user passes 32 inputs, we will
        // dispatch 1 workgroups. If the user passes 65 inputs, we will dispatch 2 workgroups, etc.
        const workgroup_size = 64;
        const workgroup_count_x = (output_size + workgroup_size - 1) / workgroup_size;
        const workgroup_count_y = 1;
        std.debug.print("workgroup_count_x: {d}\n", .{workgroup_count_x});
        std.debug.print("workgroup_count_y: {d}\n", .{workgroup_count_y});
        std.debug.print("workgroup_count_z: {d}\n", .{1});
        compute_pass.dispatchWorkgroups(workgroup_count_x, workgroup_count_y, 1);
        // Now we drop the compute pass, giving us access to the encoder again.
        compute_pass.end();

        // We add a copy operation to the encoder. This will copy the data from the output buffer on the
        // GPU to the download buffer on the CPU.
        encoder.copyBufferToBuffer(output_storage_buffer, 0, download_storage_buffer, 0, output_storage_buffer.getSize());

        // We finish the encoder, giving us a fully recorded command buffer.
        const command_buffer = encoder.finish(&wgpu.CommandBufferDescriptor{
            .label = wgpu.StringView.fromSlice("Command Buffer"),
        }).?;
        defer command_buffer.release();

        // At this point nothing has actually been executed on the gpu. We have recorded a series of
        // commands that we want to execute, but they haven't been sent to the gpu yet.
        //
        // Submitting to the queue sends the command buffer to the gpu. The gpu will then execute the
        // commands in the command buffer in order.
        queue.submit(&[_]*const wgpu.CommandBuffer{command_buffer});

        // We now map the download buffer so we can read it. Mapping tells wgpu that we want to read/write
        // to the buffer directly by the CPU and it should not permit any more GPU operations on the buffer.
        //
        // Mapping requires that the GPU be finished using the buffer before it resolves, so mapping has a callback
        // to tell you when the mapping is complete.
        var buffer_map_complete = false;
        _ = download_storage_buffer.mapAsync(wgpu.MapModes.read, 0, output_size, wgpu.BufferMapCallbackInfo{
            .callback = handleBufferMap,
            .userdata1 = @ptrCast(&buffer_map_complete),
        });

        // Wait for the GPU to finish working on the submitted work. This doesn't work on WebGPU, so we would need
        // to rely on the callback to know when the buffer is mapped.
        instance.processEvents();
        while (!buffer_map_complete) {
            instance.processEvents();
        }
        // _ = device.poll(true, null);

        // We can now read the data from the buffer.
        // Convert the data back to a slice of f32.
        const buf: [*]f32 = @ptrCast(@alignCast(download_storage_buffer.getMappedRange(0, output_size).?));
        defer download_storage_buffer.unmap();

        // Print out the result.
        std.debug.print("buf: ", .{});
        for (buf[0..output_size]) |value| {
            std.debug.print("{d} ", .{value});
        }
    }
}
