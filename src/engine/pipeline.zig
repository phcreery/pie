const std = @import("std");
const gpu = @import("gpu.zig");
const ROI = @import("ROI.zig");

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

    pub fn init(pipe: *Pipeline, desc: NodeDesc) !Node {
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

    // TODO: explicit error set
    create_nodes: *const fn (pipe: *Pipeline, mod: *Module) anyerror!void,
};

const MAX_NODES = 32;
pub const Pipeline = struct {
    allocator: std.mem.Allocator,
    gpu: gpu.GPU,
    gpu_allocator: gpu.GPUAllocator,
    nodes: std.ArrayList(Node),
    modules: std.ArrayList(Module),

    pub fn init(allocator: std.mem.Allocator) !Pipeline {
        var gpu_instance = try gpu.GPU.init();
        errdefer gpu_instance.deinit();

        var gpu_allocator = try gpu.GPUAllocator.init(&gpu_instance);
        errdefer gpu_allocator.deinit();

        const nodes = std.ArrayList(Node).initCapacity(allocator, MAX_NODES) catch unreachable;
        errdefer nodes.deinit();

        const modules = std.ArrayList(Module).initCapacity(allocator, MAX_NODES) catch unreachable;
        errdefer modules.deinit();

        return Pipeline{
            .allocator = allocator,
            .gpu = gpu_instance,
            .gpu_allocator = gpu_allocator,
            .nodes = nodes,
            .modules = modules,
        };
    }

    // pub fn addNode(self: *Pipeline, node: Node) !void {
    //     try self.nodes.append(node);
    // }

    pub fn addNodeDesc(self: *Pipeline, node_desc: NodeDesc) !void {
        const node = try Node.init(self, node_desc);
        try self.nodes.append(self.allocator, node);
    }

    pub fn addModule(self: *Pipeline, module: Module) !void {
        try self.modules.append(self.allocator, module);
        // module.create_nodes(self, &module) catch unreachable;
    }

    // Just for testing
    pub fn runWithSource(self: *Pipeline, init_contents: []f16, roi: ROI) ![]f16 {
        var module = self.modules.items[0];
        module.create_nodes(self, &module) catch unreachable;

        const node = self.nodes.items[0];
        var texture_in = try gpu.Texture.init(&self.gpu, node.desc.input_conn.format, roi);
        defer texture_in.deinit();

        var texture_out = try gpu.Texture.init(&self.gpu, node.desc.output_conn.format, roi);
        defer texture_out.deinit();

        var bindings = try gpu.Bindings.init(&self.gpu, &node.shader, &texture_in, &texture_out);
        defer bindings.deinit();

        // UPLOAD
        self.gpu_allocator.upload(f16, init_contents, .rgba16float, roi);

        // RUN
        var encoder = try gpu.Encoder.start(&self.gpu);
        defer encoder.deinit();
        encoder.enqueueBufToTex(&self.gpu_allocator, &texture_in, roi) catch unreachable;
        encoder.enqueueShader(&node.shader, &bindings, roi);
        encoder.enqueueTexToBuf(&self.gpu_allocator, &texture_out, roi) catch unreachable;
        self.gpu.run(encoder.finish()) catch unreachable;

        // DOWNLOAD
        const result = try self.gpu_allocator.download(f16, .rgba16float, roi);
        std.log.info("Download buffer contents: {any}", .{result[0..4]});

        return result;
    }

    pub fn deinit(self: *Pipeline) void {
        self.nodes.deinit(self.allocator);
        self.modules.deinit(self.allocator);
        self.gpu.deinit();
    }
};
