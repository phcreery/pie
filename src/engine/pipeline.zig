const std = @import("std");
const gpu = @import("gpu.zig");
const ROI = @import("ROI.zig");
const api = @import("api.zig");
const util = @import("util.zig");
const Module = @import("Module.zig");
const Node = @import("Node.zig");
const SingleColPool = @import("pool.zig").SingleColPool;
const DirectedGraph = @import("zig-graph/graph.zig").DirectedGraph;
const GraphPrinter = @import("zig-graph/graph.zig").print.GraphPrinter;
const slog = std.log.scoped(.pipe);

const NodePool = SingleColPool(Node);
pub const NodeHandle = NodePool.Handle;

const ConnectorPool = SingleColPool(?gpu.Texture);
pub const ConnectorHandle = ConnectorPool.Handle;

// TODO: history pool
// TODO: params pool

/// The main pipeline structure that holds modules, nodes, and manages execution.
/// This is heavily inspired by vkdt. The current difference is that modules are
/// executed in order, rather than in a DAG structure. This simplifies the execution model.
pub const Pipeline = struct {
    allocator: std.mem.Allocator,
    gpu: ?*gpu.GPU,
    gpu_allocator: ?gpu.GPUAllocator,
    node_pool: NodePool,
    node_graph: DirectedGraph(NodeHandle, ConnectorHandle, std.hash_map.AutoContext(NodeHandle)),
    node_execution_order: std.ArrayList(NodeHandle),
    modules: std.ArrayList(Module),
    connector_pool: ConnectorPool,

    pub const MAX_MODULES = 100;
    pub const MAX_NODES = 200;

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
        // var modules_pool = std.heap.MemoryPoolExtra(Module, .{}).init(allocator);
        // errdefer modules_pool.deinit();
        // const temp_module = modules_pool.create();
        // errdefer modules_pool.destroy(temp_module);
        // temp_module.* = undefined;

        const node_pool = NodePool.init(allocator);
        errdefer node_pool.deinit();

        const NodeGraph = DirectedGraph(NodeHandle, ConnectorHandle, std.hash_map.AutoContext(NodeHandle));
        var node_graph = NodeGraph.init(allocator);
        defer node_graph.deinit();

        const node_execution_order = std.ArrayList(NodeHandle).initCapacity(allocator, 2) catch unreachable;
        errdefer node_execution_order.deinit();

        const connector_pool = ConnectorPool.init(allocator);
        errdefer connector_pool.deinit();

        return Pipeline{
            .allocator = allocator,
            .gpu = gpu_instance,
            .gpu_allocator = gpu_allocator,
            .modules = modules,
            .node_pool = node_pool,
            .node_graph = node_graph,
            .node_execution_order = node_execution_order,
            .connector_pool = connector_pool,
        };
    }

    pub fn deinit(self: *Pipeline) void {
        self.modules.deinit(self.allocator);
        self.node_execution_order.deinit(self.allocator);
        self.node_graph.deinit();
        // the pool deinit will take care of deallocating the textures
        self.node_pool.deinit();
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
        return try self.node_pool.add(node);
    }

    pub fn copyConnector(
        self: *Pipeline,
        mod: *Module,
        mod_socket_name: []const u8,
        node_handle: NodeHandle,
        node_socket_name: []const u8,
    ) !void {
        slog.info("Connecting module {s} socket {s} to node {any} socket {s}", .{ mod.desc.name, mod_socket_name, node_handle, node_socket_name });
        // TODO: some checks for socket compatibility

        const module_socket = mod.getSocket(mod_socket_name) orelse unreachable;

        var node = self.node_pool.getPtr(node_handle) catch unreachable;
        const node_socket_idx = node.getSocketIndex(node_socket_name) orelse unreachable;

        node.desc.sockets[node_socket_idx] = module_socket;
    }

    pub fn runModulesCheck(self: *Pipeline) !void {
        for (self.modules.items) |module| {
            if (module.desc.type == .source) {
                if (module.desc.input_socket != null) {
                    slog.err("Source module {s} has an input socket defined", .{module.desc.name});
                    return error.ModuleSourceHasInputSocket;
                }
            }
            if (module.desc.type == .compute) {
                if (module.desc.input_socket == null) {
                    slog.err("Compute module {s} has no input socket defined", .{module.desc.name});
                    return error.ModuleComputeMissingInputSocket;
                }
                if (module.desc.output_socket == null) {
                    slog.err("Compute module {s} has no output socket defined", .{module.desc.name});
                    return error.ModuleComputeMissingOutputSocket;
                }
            }
        }
    }

    /// configure ROI for input sockets and output sockets
    pub fn runModulesModifyROIOut(self: *Pipeline) !void {
        var prev_out_roi: ?ROI = null;
        for (self.modules.items) |*module| {
            if (module.enabled == false) continue;

            // if the input socket ROI is not set, use the previous module's output socket ROI
            if (module.desc.type != .source) {
                // TODO: check connection first
                if (prev_out_roi != null) {
                    module.desc.input_socket.?.roi = prev_out_roi;
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
                if (module.desc.type != .source and module.desc.type != .sink) {
                    module.desc.output_socket.?.roi = module.desc.input_socket.?.roi;
                }
            }

            if (module.desc.type != .sink) {
                // update prev_out_roi for use on the next module
                if (module.desc.output_socket) |output_socket| {
                    prev_out_roi = output_socket.roi;
                } else {
                    slog.err("Module {s} has no output sock ROI set", .{module.desc.name});
                    return error.ModuleMissingOutputSockROI;
                }
            }
        }
    }

    /// configure connectors only for module output connectors
    pub fn runModulesCreateConnectorHandles(self: *Pipeline) !void {
        var prev_conn_handle: ?ConnectorHandle = null;
        for (self.modules.items) |*module| {
            slog.info("Configuring connectors for module: {s}", .{module.desc.name});
            if (module.enabled == false) continue;

            // if the input socket is not set, use the previous module's output socket
            if (module.desc.type != .source) {
                if (prev_conn_handle != null) {
                    slog.info("Module {s} input connector set to previous output connector", .{module.desc.name});
                    if (module.desc.input_socket) |*sock| {
                        sock.private.conn_handle = prev_conn_handle;
                    } else {
                        slog.err("Module {s} has no input socket to set connector on", .{module.desc.name});
                        return error.ModuleMissingInputSock;
                    }
                } else {
                    slog.err("Module {s} has no input connector and no previous module to get it from", .{module.desc.name});
                    return error.ModuleMissingInputSock;
                }
            }

            // TODO: check output connectors before configuring

            // once the output connector is defined, create a new connector in the pool
            if (module.desc.output_socket) |*sock| {
                slog.info("Configuring output connector image for module: {s}", .{module.desc.name});
                sock.private.conn_handle = try self.connector_pool.add(null);
                prev_conn_handle = sock.private.conn_handle;
            }
        }
    }

    /// create nodes for each module
    pub fn runModulesCreateNodes(self: *Pipeline) !void {
        for (self.modules.items) |*module| {
            if (module.enabled == false) continue;
            if (module.desc.createNodes) |createNodesFn| {
                try createNodesFn(self, module);
            }
        }
    }

    pub fn runModules(self: *Pipeline) !void {
        try self.runModulesCheck();
        try self.runModulesModifyROIOut();
        try self.runModulesCreateConnectorHandles();
        try self.runModulesCreateNodes();
    }

    /// Builds a DAG graph for the node by connecting nodes based on matching connector handles
    /// then performs a DFS to determine execution order
    pub fn runNodesBuildExecutionOrder(self: *Pipeline) !void {
        // TODO: make this better
        // first build the graph by connecting nodes based on matching connector handles
        var node_pool_handles_a = self.node_pool.liveHandles();
        // var first_node_handle: ?NodeHandle = null;
        while (node_pool_handles_a.next()) |node_handle_a| {
            // std.debug.print("Processing node: {any}\n", .{node_handle_a});
            // if (first_node_handle == null) {
            //     // set first node handle
            //     first_node_handle = node_handle_a;
            // }
            var node_pool_handles_b = self.node_pool.liveHandles();
            while (node_pool_handles_b.next()) |node_handle_b| {
                // slog.info("Checking for edge between node {any} and node {any}", .{ node_handle_a, node_handle_b });
                // skip if edge already exists
                if (self.node_graph.getEdge(node_handle_a, node_handle_b) != null) continue;
                if (self.node_graph.getEdge(node_handle_b, node_handle_a) != null) continue;
                if (node_handle_a.id == node_handle_b.id) continue;
                // add nodes to graph
                self.node_graph.add(node_handle_a) catch unreachable;
                self.node_graph.add(node_handle_b) catch unreachable;
                // get connector handle
                const node_a = self.node_pool.get(node_handle_a) catch unreachable;
                const node_b = self.node_pool.get(node_handle_b) catch unreachable;
                // check for matching connector handles
                var found_match = false;
                var match_handle: ?ConnectorHandle = null;
                for (node_a.desc.sockets) |socket_a| {
                    const sock_a = socket_a orelse continue;
                    for (node_b.desc.sockets) |socket_b| {
                        const sock_b = socket_b orelse continue;
                        const conn_handle_a = sock_a.private.conn_handle orelse continue;
                        const conn_handle_b = sock_b.private.conn_handle orelse continue;
                        if (conn_handle_a.id == conn_handle_b.id) {
                            found_match = true;
                            match_handle = conn_handle_a;
                            break;
                        }
                    }
                    if (found_match) break;
                }
                if (found_match) {
                    slog.info("Adding edge from node {any} to node {any}", .{ node_handle_a, node_handle_b });
                    self.node_graph.addEdge(node_handle_a, node_handle_b, match_handle.?) catch unreachable;
                }
            }
        }
        // perform topological sort from first node to get execution order
        // if (first_node_handle) |h| {
        // }
        var iter = try self.node_graph.topSortIterator();
        defer iter.deinit();
        while (try iter.next()) |value| {
            try self.node_execution_order.append(self.allocator, self.node_graph.lookup(value).?);
        }
        slog.info("Topological sorted order: {any}", .{self.node_execution_order.items});
    }

    /// Allocates output textures and creates compute shaders for each node
    /// also creates bindings for each shader
    ///
    /// similar to vkdt dt_graph_run_nodes_allocate()
    pub fn runNodesAllocate(self: *Pipeline) !void {
        const gpu_inst = self.gpu orelse return error.PipelineNoGPUInstance;
        // PASS #1 - allocate output textures and create compute shaders for each node
        for (self.node_execution_order.items) |node_handle| {
            const node = self.node_pool.getPtr(node_handle) catch unreachable;
            slog.info("Allocating resources for node with shader entry point: {s}", .{node.desc.entry_point});

            var bind_group_layout: [gpu.MAX_BINDINGS]?gpu.BindGroupLayoutEntry = @splat(null);
            var bind_group: [gpu.MAX_BINDINGS]?gpu.BindGroupEntry = @splat(null);
            // var shader_conns = std.ArrayList(gpu.BindGroupLayoutEntry).initCapacity(self.allocator, 0) catch unreachable;
            // defer shader_conns.deinit(self.allocator);

            for (node.desc.sockets, 0..) |socket, binding_number| {
                if (socket) |sock| {
                    // slog.info("Node socket: {s}, type: {s}, format: {s}, roi: {any}", .{ sock.name, @tagName(sock.type), @tagName(sock.format), sock.roi });

                    if (sock.type.direction() == .output) {
                        const conn_handle = sock.private.conn_handle orelse return error.NodeOutputSocketMissingConnectorHandle;
                        slog.info("Allocating output texture for node socket {s} with connector handle {any}", .{ sock.name, conn_handle });
                        var buf: [256]u8 = undefined;
                        const str = try std.fmt.bufPrint(&buf, "id: {d}", .{conn_handle.id});
                        const texture = try gpu.Texture.init(gpu_inst, str, sock.format, sock.roi.?);
                        // defer texture.deinit();
                        // store texture in connector pool
                        const conn = try self.connector_pool.getPtr(conn_handle);
                        conn.* = texture;
                    }
                    if (node.desc.type == .compute) {
                        // prepare shader pipe connections
                        bind_group_layout[binding_number] = gpu.BindGroupLayoutEntry{
                            .binding = @intCast(binding_number),
                            .type = sock.type.toShaderPipeBindGroupLayoutEntryType(),
                            .format = sock.format,
                        };
                        slog.info("Added bind group layout entry for binding {d}, type {s}, format {s}", .{ binding_number, @tagName(bind_group_layout[binding_number].?.type), @tagName(bind_group_layout[binding_number].?.format) });

                        const conn_handle = sock.private.conn_handle orelse return error.NodeOutputSocketMissingConnectorHandle;
                        const conn = try self.connector_pool.getPtr(conn_handle);
                        const texture = conn.* orelse return error.NodeSocketMissingConnectorTexture;
                        bind_group[binding_number] = gpu.BindGroupEntry{
                            .type = gpu.BindGroupEntryType.texture,
                            .binding = @intCast(binding_number),
                            .texture = texture,
                        };
                    }
                }
            }

            if (node.desc.type == .compute) {
                slog.info("Creating shader for node with entry point: {s}", .{node.desc.entry_point});
                const shader = try gpu.ShaderPipe.init(
                    gpu_inst,
                    node.desc.shader_code,
                    node.desc.entry_point,
                    bind_group_layout,
                );
                node.shader = shader;

                const bindings = try gpu.Bindings.init(gpu_inst, &shader, bind_group);
                // defer bindings.deinit();
                node.bindings = bindings;
            }
        }
    }

    /// Calls module readSource() functions to upload source data to GPU
    ///
    /// similar to vkdt dt_graph_run_nodes_upload()
    pub fn runNodesUpload(self: *Pipeline) !void {
        var gpu_allocator = self.gpu_allocator orelse return error.PipelineMissingGPUAllocator;

        // we currently only support one upload in the entire pipeline
        // so we are going check if the first node has a source connector
        const first_node_handle = self.node_execution_order.items[0];
        const first_node = self.node_pool.get(first_node_handle) catch unreachable;

        // TODO: support multiple source uploads in the future
        // TODO: find the correct input socket by type
        if (first_node.desc.sockets[0]) |sock| {
            if (sock.type == .source) {
                if (first_node.mod.desc.readSource) |readSourceFn| {
                    slog.info("Uploading source data for first node", .{});

                    // we are going to create a staging buffer here and pass the mapped pointer to the readSource function
                    const size_bytes = sock.roi.?.size.w * sock.roi.?.size.h * sock.format.bpp();
                    const upload_buffer_ptr: *anyopaque = gpu_allocator.mapUpload(size_bytes);
                    defer gpu_allocator.unmapUpload();

                    // then the node can do the upload with
                    // const upload_buffer_ptr: [*]f16 = @ptrCast(@alignCast(mapped));
                    // @memcpy(upload_buffer_ptr, data);

                    readSourceFn(self, first_node.mod, upload_buffer_ptr) catch unreachable;
                }
            } else {
                slog.err("First node input socket is not of type source, skipping upload", .{});
            }
        }
    }
    // pub fn runModulesUploadUniforms(self: *Pipeline) !void {}
    pub fn runNodes(self: *Pipeline) !void {
        const gpu_inst = self.gpu orelse return error.PipelineNoGPUInstance;
        var gpu_allocator = self.gpu_allocator orelse return error.PipelineMissingGPUAllocator;

        var encoder = try gpu.Encoder.start(gpu_inst);
        defer encoder.deinit();

        // enqueue each node in execution order
        for (self.node_execution_order.items) |node_handle| {
            const node = self.node_pool.getPtr(node_handle) catch unreachable;
            switch (node.desc.type) {
                .compute => {
                    if (node.shader) |*shader| {
                        if (node.bindings) |*bindings| {
                            slog.info("Enqueueing compute shader for node {s}", .{node.desc.entry_point});
                            encoder.enqueueShader(shader, bindings, node.desc.run_size.?);
                        } else {
                            slog.err("Node {any} has no bindings assigned", .{node_handle});
                            return error.NodeMissingBindings;
                        }
                    }
                },
                .source => {
                    slog.info("Enqueueing source node {s} buffer to texture copy", .{node.desc.entry_point});
                    const texture = self.connector_pool.getPtr(node.desc.sockets[0].?.private.conn_handle.?) catch unreachable;
                    var tex = texture.* orelse return error.PipelineMissingSourceNodeTexture;
                    encoder.enqueueBufToTex(
                        &gpu_allocator,
                        &tex,
                        node.desc.sockets[0].?.roi.?,
                    ) catch unreachable;
                },
                .sink => {
                    slog.info("Enqueueing sink node {s} texture to buffer copy", .{node.desc.entry_point});
                    const texture = self.connector_pool.getPtr(node.desc.sockets[0].?.private.conn_handle.?) catch unreachable;
                    var tex = texture.* orelse return error.PipelineMissingSinkNodeTexture;
                    encoder.enqueueTexToBuf(
                        &gpu_allocator,
                        &tex,
                        node.desc.sockets[0].?.roi.?,
                    ) catch unreachable;
                },
            }
        }

        gpu_inst.run(encoder.finish()) catch unreachable;
    }

    pub fn runNodesDownload(self: *Pipeline) !void {
        var gpu_allocator = self.gpu_allocator orelse return error.PipelineMissingGPUAllocator;

        // we currently only support one download in the entire pipeline
        // so we are going check if the last node has a sink connector
        const last_node_handle = self.node_execution_order.items[self.node_execution_order.items.len - 1];
        const last_node = self.node_pool.get(last_node_handle) catch unreachable;

        slog.info("Last node handle: {any}", .{last_node_handle});
        // slog.info("Last node desc: {any}", .{last_node.desc});

        if (last_node.desc.sockets[0]) |sock| {
            if (sock.type == .sink) {
                if (last_node.mod.desc.writeSink) |writeSinkFn| {
                    slog.info("Downloading sink data for last node", .{});

                    const size_bytes = sock.roi.?.size.w * sock.roi.?.size.h * sock.format.bpp();
                    const download_buffer_ptr: *anyopaque = try gpu_allocator.mapDownload(size_bytes);
                    defer gpu_allocator.unmapDownload();

                    writeSinkFn(self, last_node.mod, download_buffer_ptr) catch unreachable;
                }
            } else {
                slog.err("Last node output socket is not of type sink, skipping download", .{});
            }
        }
    }

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
        self.runNodesBuildExecutionOrder() catch unreachable;
        // TODO: put these all in a loop after building execution order
        self.runNodesAllocate() catch unreachable;
        self.runNodesUpload() catch unreachable;
        // self.runModulesUploadUniforms() catch unreachable;
        self.runNodes() catch unreachable;
        self.runNodesDownload() catch unreachable;

        // util.printModules(self);
        // util.printNodes(self);
        util.printNodes2(self) catch unreachable;
    }
};
