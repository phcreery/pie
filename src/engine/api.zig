const std = @import("std");
const gpu = @import("gpu.zig");
const ROI = @import("ROI.zig");
const pipeline = @import("pipeline.zig"); // circular import?

pub const ConnType = enum {
    input,
    output,
    // source,
    // sink

    pub fn toGPUConnType(self: ConnType) gpu.ShaderPipeConnType {
        return switch (self) {
            .input => gpu.ShaderPipeConnType.input,
            .output => gpu.ShaderPipeConnType.output,
        };
    }
};

pub const Connector = struct {
    name: []const u8,
    type: ConnType,
    format: gpu.TextureFormat,
    roi: ?ROI,
};

// vkdt dt_node_t https://github.com/hanatos/vkdt/blob/632165bb3cf7d653fa322e3ffc023bdb023f5e87/src/pipe/node.h#L19
pub const NodeDesc = struct {
    shader_code: []const u8,
    entry_point: []const u8,
    run_size: ?ROI,
    // connectors: []Connector,
    input_conn: Connector,
    output_conn: Connector,
};

pub const Node = struct {
    desc: NodeDesc,
    shader: gpu.ShaderPipe,

    pub fn init(pipe: *pipeline.Pipeline, desc: NodeDesc) !Node {
        // _ = module;
        const shader = try gpu.ShaderPipe.init(
            &pipe.gpu,
            desc.shader_code,
            desc.entry_point,
            [2]gpu.ShaderPipeConn{
                .{
                    .binding = 0,
                    .type = desc.input_conn.type.toGPUConnType(),
                    .format = desc.input_conn.format,
                },
                .{
                    .binding = 1,
                    .type = desc.output_conn.type.toGPUConnType(),
                    .format = desc.output_conn.format,
                },
            },
        );
        return Node{
            .desc = desc,
            .shader = shader,
        };
    }
};

// vkdt dt_module_t https://github.com/hanatos/vkdt/blob/632165bb3cf7d653fa322e3ffc023bdb023f5e87/src/pipe/module.h#L107
// vkdt dt_module_so_t https://github.com/hanatos/vkdt/blob/632165bb3cf7d653fa322e3ffc023bdb023f5e87/src/pipe/global.h#L62
pub const Module = struct {
    name: []const u8,
    // nodes: anyerror![]Node,
    enabled: bool,

    // Use the first and last nodes connectors as module connectors
    // connectors: []Connector,
    input_conn: ?Connector,
    output_conn: ?Connector,

    // param_ui: []u8,
    // param_uniform: []u8,

    // uniform_offset: usize,
    // uniform_size: usize,

    init: ?*const fn (mod: *Module) anyerror!void,
    deinit: ?*const fn (mod: *Module) anyerror!void,
    create_nodes: ?*const fn (pipe: *pipeline.Pipeline, mod: *Module) anyerror!void,
    read_source: ?*const fn (pipe: *pipeline.Pipeline, mod: *Module, alloc: *gpu.GPUAllocator) anyerror!void,
    // write_sink: ?*const fn (pipe: *pipeline.Pipeline, mod: *Module, alloc: gpu.GPUAllocator) anyerror!void,
    modify_roi_out: ?*const fn (pipe: *pipeline.Pipeline, mod: *Module) anyerror!void,
};
