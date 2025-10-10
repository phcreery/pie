const std = @import("std");
const wgpu = @import("wgpu");
const wgpuc = @import("wgpu-c");

const output_size = 4;

fn handleBufferMap(status: wgpu.MapAsyncStatus, _: wgpu.StringView, userdata1: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    std.log.info("buffer_map status={x:.8}\n", .{@intFromEnum(status)});
    const complete: *bool = @ptrCast(@alignCast(userdata1));
    complete.* = true;
}

// Based off of headless triangle example from https://github.com/eliemichel/LearnWebGPU-Code/tree/step030-headless

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
    const COPY_BUFFER_ALIGNMENT: u64 = 4;
    const unpadded_size = @sizeOf(@TypeOf(init_contents));
    const align_mask = COPY_BUFFER_ALIGNMENT - 1;
    // const align_mask = 255;
    const padded_size = (unpadded_size + align_mask) & ~align_mask;
    // const padded_size = 4;
    std.debug.print("unpadded_size: {d}, padded_size: {d}\n", .{ unpadded_size, padded_size });

    const input_storage_buffer = device.createBuffer(&wgpu.BufferDescriptor{
        .label = wgpu.StringView.fromSlice("input_storage_buffer"),
        .usage = wgpu.BufferUsages.storage,
        .size = padded_size,
        .mapped_at_creation = @as(f32, @intFromBool(true)),
    }).?;
    defer input_storage_buffer.release();

    const buf_ptr: [*]f32 = @ptrCast(@alignCast(input_storage_buffer.getMappedRange(0, padded_size).?));
    // in rust
    // buffer.slice(..).get_mapped_range_mut()[..unpadded_size as usize]
    //             .copy_from_slice(descriptor.contents);
    // in zig
    // std.mem.copyForwards(u32, buf_ptr, init_contents[0..unpadded_size]);
    @memcpy(buf_ptr, &init_contents);
    input_storage_buffer.unmap();

    const output_storage_buffer = device.createBuffer(&wgpu.BufferDescriptor{
        .label = wgpu.StringView.fromSlice("output_storage_buffer"),
        .usage = wgpu.BufferUsages.storage | wgpu.BufferUsages.copy_src,
        .size = input_storage_buffer.getSize(),
        .mapped_at_creation = @as(u32, @intFromBool(false)),
    }).?;

    const download_storage_buffer = device.createBuffer(&wgpu.BufferDescriptor{
        .label = wgpu.StringView.fromSlice("download_storage_buffer"),
        .usage = wgpu.BufferUsages.map_read | wgpu.BufferUsages.copy_dst,
        .size = input_storage_buffer.getSize(),
        .mapped_at_creation = @as(u32, @intFromBool(false)),
    }).?;
    defer download_storage_buffer.release();

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

    const bind_group_layouts = [_]*wgpu.BindGroupLayout{bind_group_layout};
    const pipeline_layout = device.createPipelineLayout(&wgpu.PipelineLayoutDescriptor{
        .label = wgpu.StringView.fromSlice("Pipeline Layout"),
        .bind_group_layout_count = 1,
        .bind_group_layouts = &bind_group_layouts,
    }).?;

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

        const encoder = device.createCommandEncoder(&wgpu.CommandEncoderDescriptor{
            .label = wgpu.StringView.fromSlice("Command Encoder"),
        }).?;
        defer encoder.release();

        const compute_pass = encoder.beginComputePass(&wgpu.ComputePassDescriptor{
            .label = wgpu.StringView.fromSlice("Compute Pass"),
        }).?;
        compute_pass.setPipeline(pipeline);
        compute_pass.setBindGroup(0, bind_group, 0, null);

        const workgroup_size = 64;
        const workgroup_count_x = (output_size + workgroup_size - 1) / workgroup_size;
        const workgroup_count_y = 1;
        compute_pass.dispatchWorkgroups(workgroup_count_x, workgroup_count_y, 1);
        compute_pass.end();

        encoder.copyBufferToBuffer(output_storage_buffer, 0, download_storage_buffer, 0, output_storage_buffer.getSize());

        const command_buffer = encoder.finish(&wgpu.CommandBufferDescriptor{
            .label = wgpu.StringView.fromSlice("Command Buffer"),
        }).?;
        defer command_buffer.release();

        queue.submit(&[_]*const wgpu.CommandBuffer{command_buffer});

        var buffer_map_complete = false;
        _ = download_storage_buffer.mapAsync(wgpu.MapModes.read, 0, output_size, wgpu.BufferMapCallbackInfo{
            .callback = handleBufferMap,
            .userdata1 = @ptrCast(&buffer_map_complete),
        });
        instance.processEvents();
        while (!buffer_map_complete) {
            instance.processEvents();
        }
        // _ = device.poll(true, null);

        const buf: [*]f32 = @ptrCast(@alignCast(download_storage_buffer.getMappedRange(0, output_size).?));
        defer download_storage_buffer.unmap();

        // print buf
        std.debug.print("buf: ", .{});
        for (buf[0..output_size]) |value| {
            std.debug.print("{d} ", .{value});
        }
    }
}
