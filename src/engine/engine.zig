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
const Engine = struct {
    instance: *wgpu.Instance = undefined,
    adapter: *wgpu.Adapter = undefined,
    device: *wgpu.Device = undefined,
    queue: *wgpu.Queue = undefined,
    buffer_a: *wgpu.Buffer = undefined,
    buffer_b: *wgpu.Buffer = undefined,
    download_buffer: *wgpu.Buffer = undefined,
    bind_group_1: *wgpu.BindGroup = undefined,
    bind_group_2: *wgpu.BindGroup = undefined,
    bind_group_layout: *wgpu.BindGroupLayout = undefined,
    pipeline_layout: *wgpu.PipelineLayout = undefined,

    is_swapped: bool = false,

    const Self = @This();

    pub fn init() Self {
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
        const bind_group_entries_1 = [_]wgpu.BindGroupEntry{
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
        const bind_group_1 = device.createBindGroup(&wgpu.BindGroupDescriptor{
            .label = wgpu.StringView.fromSlice("Bind Group 1"),
            .layout = bind_group_layout,
            .entry_count = 2,
            .entries = &bind_group_entries_1,
        }).?;
        errdefer bind_group_1.release();
        const bind_group_entries_2 = [_]wgpu.BindGroupEntry{
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
        const bind_group_2 = device.createBindGroup(&wgpu.BindGroupDescriptor{
            .label = wgpu.StringView.fromSlice("Bind Group 2"),
            .layout = bind_group_layout,
            .entry_count = 2,
            .entries = &bind_group_entries_2,
        }).?;
        errdefer bind_group_2.release();

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
            .buffer_a = buffer_a,
            .buffer_b = buffer_b,
            .download_buffer = download_storage_buffer,
            .bind_group_1 = bind_group_1,
            .bind_group_2 = bind_group_2,
            .bind_group_layout = bind_group_layout,
            .pipeline_layout = pipeline_layout,
            .is_swapped = false,
        };
    }

    pub fn deinit(self: *Self) void {
        std.log.info("Deinitializing Engine", .{});

        self.instance.release();
        self.adapter.release();
        self.device.release();
        self.queue.release();

        self.buffer_a.release();
        self.buffer_b.release();
        self.download_buffer.release();
        self.bind_group_1.release();
        self.bind_group_2.release();
        self.bind_group_layout.release();
        self.pipeline_layout.release();
    }

    pub fn swapBuffers(self: *Self) void {
        self.is_swapped = !self.is_swapped;
    }

    pub fn writeData(self: *Self, data: []const f32) void {
        std.log.info("Writing data to GPU buffers", .{});

        // Write data to the appropriate buffer based on the swap state.
        if (self.is_swapped) {
            // Write to buffer_b
            const buffer_b_ptr: [*]f32 = @ptrCast(@alignCast(self.buffer_b.getMappedRange(0, padded_size).?));
            @memcpy(buffer_b_ptr, data);
            self.buffer_b.unmap();
        } else {
            // Write to buffer_a
            const buffer_a_ptr: [*]f32 = @ptrCast(@alignCast(self.buffer_a.getMappedRange(0, padded_size).?));
            @memcpy(buffer_a_ptr, data);
            self.buffer_a.unmap();
        }
    }
};
