const std = @import("std");
const gpu = @import("gpu.zig");
const ROI = @import("ROI.zig");
const api = @import("api.zig");

const MAX_MODULES = 100;
const MAX_NODES = 200;
pub const Pipeline = struct {
    allocator: std.mem.Allocator,
    gpu: gpu.GPU,
    gpu_allocator: gpu.GPUAllocator,
    nodes: std.ArrayList(api.Node),
    modules: std.ArrayList(api.Module),

    pub fn init(allocator: std.mem.Allocator) !Pipeline {
        var gpu_instance = try gpu.GPU.init();
        errdefer gpu_instance.deinit();

        var gpu_allocator = try gpu.GPUAllocator.init(&gpu_instance, null);
        errdefer gpu_allocator.deinit();

        // TODO: use pool (https://github.com/zig-gamedev/zpool/)
        const nodes = std.ArrayList(api.Node).initCapacity(allocator, MAX_NODES) catch unreachable;
        errdefer nodes.deinit();

        const modules = std.ArrayList(api.Module).initCapacity(allocator, MAX_NODES) catch unreachable;
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

    pub fn addNodeDesc(self: *Pipeline, node_desc: api.NodeDesc) !void {
        std.log.info("Adding node with shader entry point: {s}", .{node_desc.entry_point});
        const node = try api.Node.init(self, node_desc);
        try self.nodes.append(self.allocator, node);
    }

    pub fn addModule(self: *Pipeline, module: api.Module) !void {
        try self.modules.append(self.allocator, module);
    }

    pub fn runModules(self: *Pipeline) !void {
        // INIT
        for (self.modules.items) |*module| {
            if (module.enabled == false) continue;
            if (module.init) |init_fn| {
                try init_fn(module);
            }
        }
        // MODIFY ROI OUT
        for (self.modules.items) |*module| {
            if (module.enabled == false) continue;
            if (module.modify_roi_out) |modify_roi_out_fn| {
                try modify_roi_out_fn(self, module);
            }
        }
        // CREATE NODES
        for (self.modules.items) |*module| {
            if (module.enabled == false) continue;
            if (module.create_nodes) |create_nodes_fn| {
                try create_nodes_fn(self, module);
            }
        }
    }

    pub fn run(self: *Pipeline) !void {
        std.log.info("Running pipeline", .{});

        // First run modules so we know whaich nodes to create, what rois, what buffers and textures to allocate
        self.runModules() catch unreachable;

        // print nodes
        std.log.info("Pipeline has {d} nodes", .{self.nodes.items.len});

        // then run nodes

        // Loop thought each node
        //  first pass: find output rois
        //  If has read_source(), run it allow module to upload data to GPU
        //  then create texture for that data uploaded and transfer from buffer to texture

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
