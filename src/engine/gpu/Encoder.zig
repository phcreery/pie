const std = @import("std");
const wgpu = @import("wgpu_zig");
const ROI = @import("../ROI.zig");
const root = @import("root.zig");
const GPU = @import("GPU.zig");
const ComputePipeline = @import("ComputePipeline.zig");
const Bindings = @import("Bindings.zig");
const Buffer = @import("Buffer.zig");
const Texture = @import("Texture.zig");

const c = wgpu.c;
const slog = std.log.scoped(.gpu);

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
    const workgroup_count_x = (work_size.w + root.WORKGROUP_SIZE_X - 1) / root.WORKGROUP_SIZE_X; // ceil division
    const workgroup_count_y = (work_size.h + root.WORKGROUP_SIZE_Y - 1) / root.WORKGROUP_SIZE_Y; // ceil division
    const workgroup_count_z = 1;

    slog.debug("Dispatching compute work", .{});
    compute_pass.dispatchWorkgroups(workgroup_count_x, workgroup_count_y, workgroup_count_z);
    // Now we drop the compute pass, giving us access to the encoder again.
    compute_pass.end();
}

pub fn enqueueBufToTex(self: *Self, memory: *Buffer, mem_offset: usize, texture: *Texture, roi: ROI) !void {
    slog.debug("Writing GPU buffer to Shader Buffer", .{});

    const bytes_per_row = roi.w * texture.format.bpp();
    const padded_bytes_per_row = ((bytes_per_row + root.COPY_BYTES_PER_ROW_ALIGNMENT - 1) / root.COPY_BYTES_PER_ROW_ALIGNMENT) * root.COPY_BYTES_PER_ROW_ALIGNMENT; // ceil to next multiple of COPY_BYTES_PER_ROW_ALIGNMENT

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
    const padded_bytes_per_row = ((bytes_per_row + root.COPY_BYTES_PER_ROW_ALIGNMENT - 1) / root.COPY_BYTES_PER_ROW_ALIGNMENT) * root.COPY_BYTES_PER_ROW_ALIGNMENT; // ceil to next multiple of COPY_BYTES_PER_ROW_ALIGNMENT

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
