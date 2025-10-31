const std = @import("std");
const gpu = @import("gpu.zig");
const ROI = @import("ROI.zig");
const api = @import("api.zig");

pub const Step = struct {
    texture_in: gpu.Texture,
    texture_out: gpu.Texture,
    bindings: gpu.Bindings,
    node: *api.Node,

    pub fn init(
        texture_in: gpu.Texture,
        texture_out: gpu.Texture,
        bindings: gpu.Bindings,
        node: *api.Node,
    ) Step {
        return Step{
            .texture_in = texture_in,
            .texture_out = texture_out,
            .bindings = bindings,
            .node = node,
        };
    }

    pub fn deinit(self: *Step) void {
        self.bindings.deinit();
        self.texture_out.deinit();
        self.texture_in.deinit();
    }
};

const MAX_MODULES = 100;
const MAX_NODES = 200;
pub const Pipeline = struct {
    allocator: std.mem.Allocator,
    gpu: *gpu.GPU,
    gpu_allocator: gpu.GPUAllocator,
    nodes: std.ArrayList(api.Node),
    modules: std.ArrayList(api.Module),
    steps: std.ArrayList(Step),

    pub fn init(allocator: std.mem.Allocator) !Pipeline {
        // put gpu on the heap with allocator
        var gpu_instance = allocator.create(gpu.GPU) catch unreachable;
        errdefer allocator.destroy(gpu_instance);
        gpu_instance.* = try gpu.GPU.init();

        errdefer gpu_instance.deinit();

        var gpu_allocator = try gpu.GPUAllocator.init(gpu_instance, null);
        errdefer gpu_allocator.deinit();

        // TODO: use pool (https://github.com/zig-gamedev/zpool/)
        const modules = std.ArrayList(api.Module).initCapacity(allocator, MAX_NODES) catch unreachable;
        errdefer modules.deinit();

        const nodes = std.ArrayList(api.Node).initCapacity(allocator, MAX_NODES) catch unreachable;
        errdefer nodes.deinit();

        const steps = std.ArrayList(Step).initCapacity(allocator, MAX_NODES) catch unreachable;
        errdefer steps.deinit();

        return Pipeline{
            .allocator = allocator,
            .gpu = gpu_instance,
            .gpu_allocator = gpu_allocator,
            .modules = modules,
            .nodes = nodes,
            .steps = steps,
        };
    }

    pub fn deinit(self: *Pipeline) void {
        self.gpu_allocator.deinit();
        self.steps.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.modules.deinit(self.allocator);
        // self.gpu.deinit();
        self.allocator.destroy(self.gpu);
    }

    // pub fn addNode(self: *Pipeline, node: Node) !void {
    //     try self.nodes.append(node);
    // }

    pub fn addNodeDesc(self: *Pipeline, node_desc: api.NodeDesc) !void {
        std.log.info("Adding node with shader entry point: {s}", .{node_desc.entry_point});
        // TODO: check input connection to mach previous node output connection
        const node = try api.Node.init(self, node_desc);
        try self.nodes.append(self.allocator, node);
    }

    pub fn addModule(self: *Pipeline, module: api.Module) !void {
        try self.modules.append(self.allocator, module);
    }

    pub fn runModules(self: *Pipeline) !void {

        // SETUP ROI IN FOR FIRST MODULE
        // if (self.modules.items.len > 0) {
        //     const first_module = self.modules.items[0];
        //     if (first_module.input_conn) |input_conn| {
        //         // For now just set to some default size
        //         input_conn.roi = ROI{
        //             .offset = .{ .x = 0, .y = 0 },
        //             .size = .{ .w = 1024, .h = 768 },
        //         };
        //     }
        // }

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
            } else {
                // By default set output roi to input roi
                if (module.input_conn) |input_conn| {
                    module.output_conn.?.roi = input_conn.roi;
                }
            }
        }
        // CREATE NODES
        for (self.modules.items) |*module| {
            if (module.enabled == false) continue;
            if (module.create_nodes) |create_nodes_fn| {
                try create_nodes_fn(self, module);
            }
        }
        // READ SOURCE
        for (self.modules.items) |*module| {
            if (module.enabled == false) continue;
            if (module.read_source) |read_source_fn| {
                std.log.info("pipe self.gpu_allocator.gpu: {any}", .{@intFromPtr(self.gpu_allocator.gpu)});
                std.log.info("pipe self.gpu_allocator.gpu.instance: {any}", .{@intFromPtr(self.gpu_allocator.gpu.instance)});
                try read_source_fn(self, module, &self.gpu_allocator);
            }
        }
    }

    pub fn runNodes(self: *Pipeline) !void {
        for (self.nodes.items) |*node| {
            std.log.info("Creating step for node with shader entry point: {s}", .{node.desc.entry_point});
            // if (node.desc.input_conn.roi != null and node.desc.output_conn.roi != null) {
            // }
            // Create textures for the node's input and output connections
            var texture_in = try gpu.Texture.init(self.gpu, node.desc.input_conn.format, node.desc.input_conn.roi.?);
            // defer texture_in.deinit();
            var texture_out = try gpu.Texture.init(self.gpu, node.desc.output_conn.format, node.desc.output_conn.roi.?);
            // defer texture_out.deinit();
            const bindings = try gpu.Bindings.init(self.gpu, &node.shader, &texture_in, &texture_out);
            // defer bindings.deinit();
            const step = Step.init(texture_in, texture_out, bindings, node);
            try self.steps.append(self.allocator, step);
        }
    }

    pub fn run(self: *Pipeline) !void {
        std.log.info("Running pipeline", .{});

        // First run modules so we know whaich nodes to create, what rois, what buffers and textures to allocate
        self.runModules() catch unreachable;

        // print nodes
        std.log.info("Pipeline has {d} nodes", .{self.nodes.items.len});

        // then run nodes
        self.runNodes() catch unreachable;

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

        // STEP(
        // texture_in (node.desc.input_conn.format, node.in.roi)
        // texture_out (node.desc.output_conn.format, node.out.roi)
        // bindings
        // node
        //   .shader
        //   .run_size
        //   .in
        //     .roi
        //   .out
        //     .roi
        // )

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
};
