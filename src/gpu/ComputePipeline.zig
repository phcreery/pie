const std = @import("std");
const wgpu = @import("wgpu_zig");
const root = @import("root.zig");
const GPU = @import("GPU.zig");
const Shader = @import("Shader.zig");
const TextureFormat = @import("Texture.zig").TextureFormat;

const slog = std.log.scoped(.gpu);

name: []const u8,
wgpu_bind_group_layouts: [root.MAX_BIND_GROUPS]?wgpu.BindGroupLayout,
pipeline_layout: wgpu.PipelineLayout,
pipeline: wgpu.ComputePipeline,

const Self = @This();

pub const BindGroupLayoutEntry = struct {
    texture: ?BindGroupLayoutTextureEntry = null,
    buffer: ?BindGroupLayoutBufferEntry = null,

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
};

pub fn init(
    gpu: *GPU,
    shader: Shader,
    name: []const u8,
    bind_group_layout_entries: [root.MAX_BIND_GROUPS]?[root.MAX_BINDINGS]?BindGroupLayoutEntry,
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

    var wgpu_bind_group_layouts: [root.MAX_BIND_GROUPS]?wgpu.BindGroupLayout = @splat(null);

    var bind_group_layout_count: u32 = 0;
    bgle_blk: for (bind_group_layout_entries, 0..) |bind_group_layout, bind_group_layout_number| {
        const bgl = bind_group_layout orelse break :bgle_blk;
        var wgpu_bind_group_layout_entries: [root.MAX_BINDINGS]wgpu.BindGroupLayout.Entry = undefined;

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
                                // .access = .write_only,
                                .access = .read_write,
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

    return Self{
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
