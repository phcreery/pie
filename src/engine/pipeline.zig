const std = @import("std");
const gpu = @import("gpu.zig");
const ROI = @import("ROI.zig");
const api = @import("api.zig");
const Pool = @import("zpool").Pool;
const slog = std.log.scoped(.pipe);
const util = @import("util.zig");

// const ModulePool = Pool(16, 16, Module, struct {
//     val: Module,
// });
// const ModuleHandle = ModulePool.Handle;

const NodePool = Pool(16, 16, Node, struct {
    val: Node,
});
pub const NodeHandle = NodePool.Handle;

// TODO: history pool
// TODO: params pool

const ConnectorPool = Pool(16, 16, gpu.Texture, struct {
    val: ?gpu.Texture,
});
pub const ConnectorHandle = ConnectorPool.Handle;

pub const Module = struct {
    desc: api.ModuleDesc,
    enabled: bool,

    pub fn init(
        desc: api.ModuleDesc,
    ) !Module {
        return Module{
            .desc = desc,
            .enabled = true,
        };
    }

    // HELPER FUNCTIONS

    pub fn getSocket(mod: *Module, name: []const u8) ?api.SocketDesc {
        const sockets = [_]?api.SocketDesc{
            mod.desc.input_sock,
            mod.desc.output_sock,
        };
        for (sockets) |sock| {
            if (sock) |s| {
                if (std.mem.eql(u8, s.name, name)) {
                    slog.info("Found socket for module {s}, connector {s}", .{ mod.desc.name, name });
                    return s;
                }
            }
        }
        return null;
    }
};

pub const Node = struct {
    desc: api.NodeDesc,
    mod: *Module,
    // shader: gpu.ShaderPipe,

    // input_conn_handle: ?ConnectorHandle,
    // output_conn_handle: ?ConnectorHandle,
    conn_handles: ?[]ConnectorHandle = null,
    bindings: ?gpu.Bindings = null,

    pub fn init(
        pipe: *Pipeline,
        mod: *Module,
        desc: api.NodeDesc,
    ) !Node {
        _ = pipe;
        // _ = module;
        // TODO: don't use hardcoded 2 sockets
        // TODO: do this in the pipeline step
        // const shader = try gpu.ShaderPipe.init(
        //     pipe.gpu,
        //     desc.shader_code,
        //     desc.entry_point,
        //     [_]gpu.ShaderPipeConn{
        //         .{
        //             .binding = 0,
        //             .type = desc.sockets[0].type.toShaderPipeConnType(),
        //             .format = desc.sockets[0].format,
        //         },
        //         .{
        //             .binding = 1,
        //             .type = desc.sockets[1].type.toShaderPipeConnType(),
        //             .format = desc.sockets[1].format,
        //         },
        //     },
        // );
        return Node{
            .desc = desc,
            .mod = mod,
            // .shader = shader,
        };
    }
};

const MAX_MODULES = 100;
const MAX_NODES = 200;

/// The main pipeline structure that holds modules, nodes, and manages execution.
/// This is heavily inspired by vkdt. The current difference is that modules are
/// executed in order, rather than in a DAG structure. This simplifies the execution model.
pub const Pipeline = struct {
    allocator: std.mem.Allocator,
    gpu: ?*gpu.GPU,
    gpu_allocator: ?gpu.GPUAllocator,
    // nodes: std.ArrayList(Node),
    node_pool: NodePool,
    modules: std.ArrayList(Module),
    // module_pool: ModulePool,
    // modules_pool: std.heap.MemoryPoolExtra(Module, .{}),
    connector_pool: ConnectorPool,

    pub fn init(allocator: std.mem.Allocator, gpu_instance: ?*gpu.GPU) !Pipeline {
        if (gpu_instance == null) {
            slog.info("No GPU instance provided, performing a dry run", .{});
        }
        var gpu_allocator: ?gpu.GPUAllocator = null;
        if (gpu_instance) |gpu_inst| {
            gpu_allocator = try gpu.GPUAllocator.init(gpu_inst, null);
            errdefer gpu_allocator.deinit();
        } else {
            gpu_allocator = null;
        }

        const modules = std.ArrayList(Module).initCapacity(allocator, MAX_MODULES) catch unreachable;
        errdefer modules.deinit();
        // const module_pool = ModulePool.init(allocator);
        // errdefer module_pool.deinit();

        // TESTING
        // var modules_pool = std.heap.MemoryPoolExtra(api.Module, .{}).init(allocator);
        // errdefer modules_pool.deinit();
        // const temp_module = modules_pool.create();
        // errdefer modules_pool.destroy(temp_module);
        // temp_module.* = undefined;

        // const nodes = std.ArrayList(Node).initCapacity(allocator, MAX_NODES) catch unreachable;
        // errdefer nodes.deinit();
        const node_pool = NodePool.init(allocator);
        errdefer node_pool.deinit();

        const connector_pool = ConnectorPool.init(allocator);
        errdefer connector_pool.deinit();

        return Pipeline{
            .allocator = allocator,
            .gpu = gpu_instance,
            .gpu_allocator = gpu_allocator,
            .modules = modules,
            // .module_pool = module_pool,
            // .nodes = nodes,
            .node_pool = node_pool,
            .connector_pool = connector_pool,
        };
    }

    pub fn deinit(self: *Pipeline) void {
        self.modules.deinit(self.allocator);
        // self.module_pool.deinit();
        // self.nodes.deinit(self.allocator);
        self.node_pool.deinit();
        // the pool deinit will take care of deallocating the textures
        self.connector_pool.deinit();

        if (self.gpu_allocator) |*gpu_allocator| {
            gpu_allocator.deinit();
        }
    }

    pub fn addModuleDesc(self: *Pipeline, module_desc: api.ModuleDesc) !*Module {
        slog.info("Adding module: {s}", .{module_desc.name});
        const module = try Module.init(module_desc);
        try self.modules.append(self.allocator, module);
        return &self.modules.items[self.modules.items.len - 1];
    }

    pub fn addNodeDesc(self: *Pipeline, mod: *Module, node_desc: api.NodeDesc) !NodeHandle {
        slog.info("Adding node with shader entry point: {s}", .{node_desc.entry_point});
        // TODO: check input connection to mach previous node output connection
        const node = try Node.init(self, mod, node_desc);

        // try self.nodes.append(self.allocator, node);
        // return &self.nodes.items[self.nodes.items.len - 1];
        return try self.node_pool.add(.{
            .val = node,
        });
    }

    // pub fn connectModuleToNode(
    //     self: *Pipeline,
    //     module: *Module,
    //     node: *Node,
    // ) !void {
    //     slog.info("Connecting module {s} to node {s}", .{ module.desc.name, node.desc.entry_point });
    //     self.connector_pool.remove(node.input_conn_handle orelse return error.PipelineNodeInputConnectorNotSet) catch unreachable;
    //     node.input_conn_handle = module.output_conn_handle;
    // }

    pub fn checkModules(self: *Pipeline) !void {
        // while (self.module_pool.liveHandles().next()) |module_handle| {
        //     const module = self.module_pool.getColumn(module_handle, .val) catch unreachable;
        for (self.modules.items) |module| {
            if (module.desc.type == .source) {
                if (module.desc.input_sock != null) {
                    slog.err("Source module {s} has an input socket defined", .{module.desc.name});
                    return error.ModuleSourceHasInputSocket;
                }
            }
            if (module.desc.type == .compute) {
                if (module.desc.input_sock == null) {
                    slog.err("Compute module {s} has no input socket defined", .{module.desc.name});
                    return error.ModuleComputeMissingInputSocket;
                }
                if (module.desc.output_sock == null) {
                    slog.err("Compute module {s} has no output socket defined", .{module.desc.name});
                    return error.ModuleComputeMissingOutputSocket;
                }
            }
        }
    }

    /// configure ROI for input sockets and output sockets
    pub fn runModulesModifyROIOut(self: *Pipeline) !void {
        var prev_out_roi: ?ROI = null;
        // while (self.module_pool.liveHandles().next()) |module_handle| {
        //     var module = self.module_pool.getColumn(module_handle, .val) catch unreachable;
        for (self.modules.items) |*module| {
            if (module.enabled == false) continue;

            // if the input socket ROI is not set, use the previous module's output socket ROI
            if (module.desc.type != .source) {
                // TODO: check connection first
                if (prev_out_roi != null) {
                    module.desc.input_sock.?.roi = prev_out_roi;
                } else {
                    slog.err("Module {s} has no input sock ROI and no previous module to get it from", .{module.desc.name});
                    return error.ModuleMissingInputSockROI;
                }
            }

            // if the module has a modifyROIOut function, call it
            // else copy roi from input to output
            if (module.desc.modifyROIOut) |modifyROIOutFn| {
                try modifyROIOutFn(self, module);
            } else {
                if (module.desc.type != .source) {
                    module.desc.output_sock.?.roi = module.desc.input_sock.?.roi;
                }
            }

            // update prev_out_roi for use on the next module
            if (module.desc.output_sock) |output_sock| {
                prev_out_roi = output_sock.roi;
            } else {
                slog.err("Module {s} has no output sock ROI set", .{module.desc.name});
                return error.ModuleMissingOutputSockROI;
            }
        }
    }

    pub fn runModules(self: *Pipeline) !void {
        self.checkModules();
        self.runModulesModifyROIOut();

        // allocate images only for module output connectors
        // var prev_conn_handle: ?ConnectorHandle = null;
        // while (self.module_pool.liveHandles().next()) |module_handle| {
        //     var module = self.module_pool.getColumn(module_handle, .val) catch unreachable;
        for (self.modules.items) |*module| {
            slog.info("Configuring sockets for module: {s}", .{module.desc.name});
            if (module.enabled == false) continue;

            // if the input socket is not set, use the previous module's output socket
            // if (module.desc.type != .source) {
            //     if (prev_conn_handle != null) {
            //         slog.info("Module {s} input connector set to previous output connector", .{module.desc.name});
            //         module.input_conn_handle = prev_conn_handle;
            //     } else {
            //         slog.err("Module {s} has no input connector and no previous module to get it from", .{module.desc.name});
            //         return error.ModuleMissingInputSock;
            //     }
            // }

            // TODO: check output connectors before allocating

            // once the output connector is defined, allocate image for it
            if (module.desc.output_sock) |sock| {
                slog.info("Allocating output connector image for module: {s}", .{module.desc.name});
                slog.info("Output: {any}", .{sock});
                const texture_out = if (self.gpu) |self_gpu| gpu.Texture.init(self_gpu, sock.format, sock.roi) catch unreachable else null;
                sock.private.conn_handle = try self.connector_pool.add(.{
                    .val = texture_out,
                });
                // prev_conn_handle = module.output_conn_handle;
            }
        }

        // CREATE NODES
        // while (self.module_pool.liveHandles().next()) |module_handle| {
        //     const module = self.module_pool.getColumn(module_handle, .val) catch unreachable;
        for (self.modules.items) |*module| {
            if (module.enabled == false) continue;
            if (module.desc.createNodes) |createNodesFn| {
                try createNodesFn(self, module);
            }
        }
    }

    // similar to vkdt dt_graph_run_nodes_allocate()
    pub fn runNodesAllocate(_: *Pipeline) !void {
        // PASS #1 - allocate output buffers and create compute shaders for each node

        // THIS ALL HAS TO BE GUTTED TO RUN IN THE ORDER OF THE NODES IN THE GRAPH
        // var prev_conn_handle: ?ConnectorHandle = null;
        // var prev_sock: ?api.SocketDesc = null;
        // var node_pool_handles = self.node_pool.liveHandles();
        // while (node_pool_handles.next()) |node_handle| {
        //     var node = self.node_pool.getColumn(node_handle, .val) catch unreachable;
        //     slog.info("Creating step for node with shader entry point: {s}", .{node.desc.entry_point});

        //     // if the input socket is not set, use the previous module's output socket
        //     if (node.output_conn_handle == null) {
        //         if (prev_sock != null) {
        //             slog.info("Node {s} input sock set to previous output sock", .{node.desc.entry_point});
        //             node.desc.input_sock = prev_sock orelse return error.NodeMissingInputSock;
        //             node.input_conn_handle = prev_conn_handle;
        //         } else {
        //             slog.err("Node {s} has no input sock and no previous module to get it from", .{node.desc.entry_point});
        //             return error.NodeMissingInputSock;
        //         }
        //     }

        //     if (node.output_conn_handle == null) {
        //         slog.info("Node {s} has no output connector", .{node.desc.entry_point});
        //         node.output_conn_handle = self.connector_pool.add(.{
        //             .ptr = null,
        //             .info = .{
        //                 .name = node.desc.outputSock.name,
        //                 .format = node.desc.outputSock.format,
        //                 .roi = node.desc.outputSock.roi,
        //             },
        //         }) catch unreachable;
        //         prev_sock = node.desc.outputSock;
        //         prev_conn_handle = node.output_conn_handle;
        //     }

        //     var texture_in = try self.connector_pool.getColumn(node.input_conn_handle.?, .val) orelse return error.NodeMissingInputTexture;
        //     var texture_out = try self.connector_pool.getColumn(node.output_conn_handle.?, .val) orelse return error.NodeMissingOutputTexture;

        //     const bindings = try gpu.Bindings.init(self.gpu, &node.shader, &texture_in, &texture_out);
        //     // defer bindings.deinit();
        //     node.bindings = bindings;
        // }
    }

    pub fn runNodesUpload(_: *Pipeline) !void {
        // we currently only support one upload in the entire pipeline
        // so we are going check if the first module has a source connector
        // const first_module = self.modules.items[0];
        // if (first_module.desc.input_sock) |input_sock| {
        //     if (input_sock.type == .source) {
        //         slog.info("Uploading source data for first module", .{});
        //     } else {
        //         slog.err("First module input socket is not of type source, skipping upload", .{});
        //     }
        // }
    }
    // pub fn runModulesUploadUniforms(self: *Pipeline) !void {}
    // pub fn runNodesEnqueue(self: *Pipeline) !void {}
    // pub fn runNodes(self: *Pipeline) !void {}
    // pub fn runNodesDownload(self: *Pipeline) !void {}

    pub fn run(self: *Pipeline) !void {

        // Order of Operations:
        // dt_graph_run_modules
        // - modifyROIOut
        // - modify_roi_in
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

        slog.info("Running pipeline", .{});

        // First run modules so we know which nodes to create, what rois, what buffers and textures to allocate
        self.runModules() catch unreachable;

        // then run nodes
        self.runNodesAllocate() catch unreachable;
        self.runNodesUpload() catch unreachable;

        util.printModules(self);
        util.printNodes(self);

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
        slog.info("Download buffer contents: {any}", .{result[0..4]});

        return result;
    }
};
