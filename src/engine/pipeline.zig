const std = @import("std");
const gpu = @import("gpu.zig");
const ROI = @import("ROI.zig");
const api = @import("api.zig");
const Pool = @import("zpool").Pool;

// const ModulePool = Pool(16, 16, gpu.Texture, struct {
//     ptr: gpu.Texture,
//     info: api.Module,
// });
// const ModuleHandle = ModulePool.Handle;

const ConnectorPool = Pool(16, 16, gpu.Texture, struct {
    ptr: gpu.Texture,
    info: api.ConnectorDesc,
});
const ConnectorHandle = ConnectorPool.Handle;

pub const Module = struct {
    desc: api.ModuleDesc,

    input_conn_handle: ?ConnectorHandle,
    output_conn_handle: ?ConnectorHandle,

    pub fn init(
        pipe: *Pipeline,
        desc: api.ModuleDesc,
    ) !Module {
        _ = pipe;
        return Module{
            .desc = desc,
            .input_conn_handle = null,
            .output_conn_handle = null,
        };
    }
};

pub const Node = struct {
    desc: api.NodeDesc,
    shader: gpu.ShaderPipe,

    input_conn_handle: ?ConnectorHandle,
    output_conn_handle: ?ConnectorHandle,
    bindings: ?gpu.Bindings,

    pub fn init(
        pipe: *Pipeline,
        desc: api.NodeDesc,
    ) !Node {
        // _ = module;
        const shader = try gpu.ShaderPipe.init(
            pipe.gpu,
            desc.shader_code,
            desc.entry_point,
            [2]gpu.ShaderPipeConn{
                .{
                    .binding = 0,
                    .type = desc.input_conn.type.toShaderPipeConnType(),
                    .format = desc.input_conn.format,
                },
                .{
                    .binding = 1,
                    .type = desc.output_conn.type.toShaderPipeConnType(),
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

const MAX_MODULES = 100;
const MAX_NODES = 200;
pub const Pipeline = struct {
    allocator: std.mem.Allocator,
    gpu: *gpu.GPU,
    gpu_allocator: gpu.GPUAllocator,
    nodes: std.ArrayList(Node),
    modules: std.ArrayList(api.Module),
    // modules: std.ArrayList(*api.Module),
    modules_pool: std.heap.MemoryPoolExtra(api.Module, .{}),
    connector_pool: ConnectorPool,

    pub fn init(allocator: std.mem.Allocator) !Pipeline {
        // put gpu instance on the heap
        var gpu_instance = allocator.create(gpu.GPU) catch unreachable;
        errdefer allocator.destroy(gpu_instance);
        gpu_instance.* = try gpu.GPU.init();
        errdefer gpu_instance.deinit();

        var gpu_allocator = try gpu.GPUAllocator.init(gpu_instance, null);
        errdefer gpu_allocator.deinit();

        const modules = std.ArrayList(api.Module).initCapacity(allocator, MAX_MODULES) catch unreachable;
        errdefer modules.deinit();

        // var modules_pool = std.heap.MemoryPoolExtra(api.Module, .{}).init(allocator);
        // errdefer modules_pool.deinit();
        // const modules = std.ArrayList(*api.Module).initCapacity(allocator, MAX_MODULES) catch unreachable;
        // errdefer modules.deinit();

        const nodes = std.ArrayList(Node).initCapacity(allocator, MAX_NODES) catch unreachable;
        errdefer nodes.deinit();

        const connector_pool = ConnectorPool.init(allocator);
        errdefer connector_pool.deinit();

        // connectors.

        return Pipeline{
            .allocator = allocator,
            .gpu = gpu_instance,
            .gpu_allocator = gpu_allocator,
            .modules = modules,
            // .modules_pool = modules_pool,
            .nodes = nodes,
            .connector_pool = connector_pool,
        };
    }

    pub fn deinit(self: *Pipeline) void {
        self.gpu_allocator.deinit();
        self.nodes.deinit(self.allocator);
        self.modules.deinit(self.allocator);
        self.gpu.deinit();
        self.allocator.destroy(self.gpu);
    }

    // pub fn addNode(self: *Pipeline, node: Node) !void {
    //     try self.nodes.append(node);
    // }

    pub fn addNodeDesc(self: *Pipeline, node_desc: api.NodeDesc) !*Node {
        std.log.info("Adding node with shader entry point: {s}", .{node_desc.entry_point});
        // TODO: check input connection to mach previous node output connection
        const node = try Node.init(self, node_desc);
        try self.nodes.append(self.allocator, node);
        return &self.nodes.items[self.nodes.items.len - 1];
    }

    pub fn addModuleDesc(self: *Pipeline, module_desc: api.ModuleDesc) !*Module {
        std.log.info("Adding module: {s}", .{module_desc.name});
        const module = try Module.init(self, module_desc);
        try self.modules.append(self.allocator, module);
        return &self.modules.items[self.modules.items.len - 1];
    }

    pub fn runModules(self: *Pipeline) !void {

        // INIT
        // for (self.modules.items) |*module| {
        //     if (module.enabled == false) continue;
        //     if (module.init) |init_fn| {
        //         try init_fn(module);
        //     }
        // }
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
        // init_connector_images
        // for (self.modules.items) |*module| {
        //     if (module.enabled == false) continue;
        //     if (module.read_source) |read_source_fn| {
        //         try read_source_fn(self, module, &self.gpu_allocator);
        //     }
        // }
    }

    // dt_graph_run_nodes_allocate
    pub fn runNodesAllocate(self: *Pipeline) !void {
        // PASS #1 - allocate output buffers and create compute shaders for each node
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
        }
    }

    pub fn runNodesUpload(self: *Pipeline) !void {
        // we currently only support one upload in the entire pipeline
        // so we are going check if the first module has a source connector
        const first_module = self.modules.items[0];
        if (first_module.input_conn) |input_conn| {
            if (input_conn.type == .source) {
                std.log.info("Uploading source data for first module", .{});
            } else {
                std.log.err("First module input connector is not of type source, skipping upload", .{});
            }
        }
    }
    // pub fn runModulesUploadUniforms(self: *Pipeline) !void {}
    // pub fn runNodesEnqueue(self: *Pipeline) !void {}
    // pub fn runNodes(self: *Pipeline) !void {}
    // pub fn runNodesDownload(self: *Pipeline) !void {}

    pub fn run(self: *Pipeline) !void {

        // Order of Operations:
        // dt_graph_run_modules
        // - modify_roi_out
        // - create_nodes
        //   - module.create_nodes() called here
        //   - handles bypassing disabled nodes
        // - init_connector_images
        //   - // only allocate memory for output connectors ("write" or "source" types)
        //
        // dt_graph_run_nodes_allocate     (potentially free/re-allocate memory, create buffers, images, image_views, and descriptor sets)
        // - 1. alloc_outputs()  allocate output buffers and create compute shaders for each node
        // - 2. alloc_outputs2() bind_buffers_to_memory (vkBindImageMemory)
        // - 3. alloc_outputs3() create_descriptor_sets for each node
        // dt_graph_run_nodes_upload       (upload all source data to staging memory) (read_source called here)
        // dt_graph_run_modules_upload_uniforms
        // dt_graph_run_nodes_record_cmd
        // (submit queue)
        // dt_graph_run_nodes_download     (download sink data from GPU to CPU)

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

        // ALLOCATE
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
};
