//! The Bindings (bind group) contains the actual resources to bind to the pipeline.
//! Similar to vulkan's descriptor sets, a Bindings struct holds the actual resources
//! (buffers, textures, etc) that are bound to a shader pipeline.
const std = @import("std");
const wgpu = @import("wgpu_zig");
const root = @import("root.zig");
const GPU = @import("GPU.zig");
const ComputePipeline = @import("ComputePipeline.zig");
const Texture = @import("Texture.zig");
const Buffer = @import("Buffer.zig");

const slog = std.log.scoped(.gpu);

bind_groups: [root.MAX_BIND_GROUPS]?wgpu.BindGroup,

const Self = @This();

pub const BindGroupEntry = struct {
    texture: ?Texture = null,
    buffer: ?Buffer = null,
};

pub fn init(
    gpu: *GPU,
    compute_pipeline: *const ComputePipeline,
    bind_group_entries: [root.MAX_BIND_GROUPS]?[root.MAX_BINDINGS]?BindGroupEntry,
) !Self {
    slog.debug("Creating Bindings", .{});

    // Even when the buffers are individually dropped, wgpu will keep the bind group and buffers
    // alive until the bind group itself is dropped.
    var bind_groups: [root.MAX_BIND_GROUPS]?wgpu.BindGroup = @splat(null);
    for (bind_group_entries, 0..) |bind_group, bind_group_number| {
        var wgpu_bind_group_entries: [root.MAX_BINDINGS]wgpu.BindGroup.Entry = undefined;
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
    return Self{
        .bind_groups = bind_groups,
    };
}

pub fn deinit(self: *Self) void {
    for (self.bind_groups) |bind_group| {
        const bg = bind_group orelse continue;
        bg.deinit();
    }
}
