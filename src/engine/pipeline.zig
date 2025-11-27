const std = @import("std");
const gpu = @import("gpu.zig");
const ROI = @import("ROI.zig");
const api = @import("modules/api.zig");
const util = @import("util.zig");
const Module = @import("Module.zig");
const Node = @import("Node.zig");
const HashMapPool = @import("pool_hash_map.zig").HashMapPool;
const DirectedGraph = @import("zig-graph/graph.zig").DirectedGraph;
const GraphPrinter = @import("zig-graph/graph.zig").print.GraphPrinter;
const slog = std.log.scoped(.pipe);

const NodePool = HashMapPool(Node);
pub const NodeHandle = NodePool.Handle;

const ConnectorPool = HashMapPool(?gpu.Texture);
pub const ConnectorHandle = ConnectorPool.Handle;

const ParamBufferPool = HashMapPool(?gpu.Buffer);
pub const ParamBufferHandle = ParamBufferPool.Handle;

// TODO: params pool
// TODO: history pool

/// The main pipeline structure that holds modules, nodes, and manages execution.
/// This is heavily inspired by vkdt.
///
/// The current difference is that modules are executed in order, rather than
/// in a DAG structure. This simplifies the execution model but I might change this later.
///
/// A couple rules:
/// - Source modules must have a source output socket and no input socket
/// - Source modules must create a single source node
/// - Sink modules must have a sink input socket and no output socket
/// - Sink modules must create a single sink node
/// - Nodes added to the pipeline must be run in the order they are added
///     - this is needed for determining the proper edge direction in the DAG
///     - vkdt does not need this because it builds the graph based on a field
///       .connected_to for input sockets in the node struct
pub const Pipeline = struct {
    allocator: std.mem.Allocator,
    gpu: ?*gpu.GPU,

    upload_buffer: ?gpu.Buffer,
    upload_fba: ?std.heap.FixedBufferAllocator,

    download_buffer: ?gpu.Buffer,
    download_fba: ?std.heap.FixedBufferAllocator,

    node_pool: NodePool,
    node_graph: DirectedGraph(NodeHandle, ConnectorHandle, std.hash_map.AutoContext(NodeHandle)),
    node_execution_order: std.ArrayList(NodeHandle),

    modules: std.ArrayList(Module),
    // modules_pool: std.heap.MemoryPoolExtra(Module, .{}),

    connector_pool: ConnectorPool,

    param_buffer_pool: ParamBufferPool,

    pub const MAX_MODULES = 100;
    pub const MAX_NODES = 200;

    pub fn init(allocator: std.mem.Allocator, gpu_instance: ?*gpu.GPU) !Pipeline {
        if (gpu_instance == null) {
            slog.debug("No GPU instance provided, performing a dry run", .{});
        }
        var upload_buffer: ?gpu.Buffer = null;
        var upload_fba: ?std.heap.FixedBufferAllocator = null;
        var download_buffer: ?gpu.Buffer = null;
        var download_fba: ?std.heap.FixedBufferAllocator = null;
        if (gpu_instance) |gpu_inst| {
            upload_buffer = try gpu.Buffer.init(gpu_inst, null, .upload);
            if (upload_buffer) |*ub| {
                upload_fba = ub.fixedBufferAllocator();
                errdefer ub.deinit();
            }
            download_buffer = try gpu.Buffer.init(gpu_inst, null, .download);
            if (download_buffer) |*db| {
                download_fba = db.fixedBufferAllocator();
                errdefer db.deinit();
            }
        } else {
            upload_buffer = null;
        }

        const modules = std.ArrayList(Module).initCapacity(allocator, MAX_MODULES) catch unreachable;
        errdefer modules.deinit();
        // const module_pool = ModulePool.init(allocator);
        // errdefer module_pool.deinit();

        const node_pool = NodePool.init(allocator);
        errdefer node_pool.deinit();

        const NodeGraph = DirectedGraph(NodeHandle, ConnectorHandle, std.hash_map.AutoContext(NodeHandle));
        var node_graph = NodeGraph.init(allocator);
        defer node_graph.deinit();

        const node_execution_order = std.ArrayList(NodeHandle).initCapacity(allocator, 2) catch unreachable;
        errdefer node_execution_order.deinit();

        const connector_pool = ConnectorPool.init(allocator);
        errdefer connector_pool.deinit();

        const param_buffer_pool = ParamBufferPool.init(allocator);
        errdefer param_buffer_pool.deinit();

        return Pipeline{
            .allocator = allocator,
            .gpu = gpu_instance,

            .upload_buffer = upload_buffer,
            .upload_fba = upload_fba,

            .download_buffer = download_buffer,
            .download_fba = download_fba,

            .modules = modules,
            // .modules_pool = modules_pool,

            .node_pool = node_pool,
            .node_graph = node_graph,
            .node_execution_order = node_execution_order,

            .connector_pool = connector_pool,

            .param_buffer_pool = param_buffer_pool,
        };
    }

    pub fn deinit(self: *Pipeline) void {
        slog.debug("De-initializing Pipeline", .{});
        self.modules.deinit(self.allocator);
        self.node_execution_order.deinit(self.allocator);
        self.node_graph.deinit();
        // the pool deinit will take care of deallocating the textures
        self.node_pool.deinit();
        self.connector_pool.deinit();
        self.param_buffer_pool.deinit();

        if (self.upload_buffer) |*upload_buffer| {
            upload_buffer.deinit();
        }
        if (self.download_buffer) |*download_buffer| {
            download_buffer.deinit();
        }
    }

    pub fn addModule(self: *Pipeline, module_desc: api.ModuleDesc) !*Module {
        slog.debug("Adding module: {s}", .{module_desc.name});
        const module = try Module.init(module_desc);
        try self.modules.append(self.allocator, module);
        return &self.modules.items[self.modules.items.len - 1];
        // const module_ptr = try self.modules_pool.create();
        // module_ptr.* = module;
        // return module_ptr;
    }

    pub fn addNode(self: *Pipeline, mod: *Module, node_desc: api.NodeDesc) !NodeHandle {
        slog.debug("Adding node with shader entry point: {s}", .{node_desc.entry_point});
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
        slog.debug("Connecting module {s} socket {s} to node {any} socket {s}", .{ mod.desc.name, mod_socket_name, node_handle, node_socket_name });
        // TODO: some checks for socket compatibility

        const module_socket = mod.getSocket(mod_socket_name) orelse unreachable;

        var node = self.node_pool.getPtr(node_handle) catch unreachable;
        const node_socket_idx = node.getSocketIndex(node_socket_name) orelse unreachable;

        node.desc.sockets[node_socket_idx] = module_socket;
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

        slog.debug("Running pipeline", .{});

        // First run modules so we know which nodes to create, what rois, buffers, and textures to allocate
        self.runModulesPreCheck() catch unreachable;
        self.runModulesModifyROIOut() catch unreachable;
        self.runModulesCreateConnectorHandles() catch unreachable;

        self.runModulesInitParamBuffers() catch unreachable;
        self.runModulesAllocateUploadBufferForParams() catch unreachable;
        self.runModulesCreateNodes() catch unreachable;

        // Then run nodes
        self.runNodesBuildExecutionOrder() catch unreachable;
        // TODO: put these all in a single loop after building execution order
        self.runNodesInitConnectorTextures() catch unreachable;
        self.runNodesAllocateUploadBufferForTextures() catch unreachable;
        self.runNodesCreateBindings() catch unreachable;

        self.print();

        self.runModulesUploadParams() catch unreachable;
        self.runNodesUploadSource() catch unreachable;
        self.runNodes() catch unreachable;
        self.runNodesDownloadSink() catch unreachable;
    }

    pub fn print(self: *Pipeline) void {
        // util.printModules(self);
        util.printNodes(self);
        util.printNodes2(self) catch unreachable;
    }

    fn runModulesPreCheck(self: *Pipeline) !void {
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
    fn runModulesModifyROIOut(self: *Pipeline) !void {
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
    fn runModulesCreateConnectorHandles(self: *Pipeline) !void {
        var prev_conn_handle: ?ConnectorHandle = null;
        for (self.modules.items) |*module| {
            // slog.debug("Configuring connectors for module: {s}", .{module.desc.name});
            if (module.enabled == false) continue;

            // if the input socket is not set, use the previous module's output socket
            if (module.desc.type != .source) {
                if (prev_conn_handle != null) {
                    slog.debug("Module {s} input connector set to previous output connector", .{module.desc.name});
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
                // slog.debug("Configuring output connector image for module: {s}", .{module.desc.name});
                sock.private.conn_handle = try self.connector_pool.add(null);
                prev_conn_handle = sock.private.conn_handle;
            }

            // create params buffer
            const param_buffer = try self.param_buffer_pool.add(null);
            module.param_handle = param_buffer;
            module.param_offset = 0;
            module.param_size = 0;
        }
    }

    fn runModulesInitParamBuffers(self: *Pipeline) !void {
        const gpu_inst = self.gpu orelse return error.PipelineNoGPUInstance;
        for (self.modules.items) |*module| {
            const param_handle = module.param_handle orelse return error.NodeOutputSocketMissingConnectorHandle;

            const size_bytes = @sizeOf(f32); // TODO: use module.desc.param_size
            const buffer = try gpu.Buffer.init(gpu_inst, size_bytes, .storage);
            // defer texture.deinit();
            // store texture in connector pool
            const param = try self.param_buffer_pool.getPtr(param_handle);
            param.* = buffer;
        }
    }

    fn runModulesAllocateUploadBufferForParams(self: *Pipeline) !void {
        if (self.upload_fba) |*upload_fba| {
            var upload_allocator = upload_fba.allocator();

            for (self.modules.items) |*module| {
                if (module.desc.type == .compute) {
                    if (module.enabled == false) continue;
                    const size_bytes = @sizeOf(f32); // TODO: use module.desc.param_size
                    slog.debug("Allocating upload buffer for params for size {d} bytes", .{size_bytes});
                    const mapped_param_buf_slice = try upload_allocator.alignedAlloc(f32, .@"16", 1);

                    module.param_size = size_bytes;
                    const param_offset = @intFromPtr(mapped_param_buf_slice.ptr) - @intFromPtr(upload_fba.buffer.ptr);
                    module.param_offset = param_offset;
                    module.mapped_param_buf_slice = mapped_param_buf_slice;
                }
            }
        }
    }

    pub fn runModulesUploadParams(self: *Pipeline) !void {
        var upload_buffer = self.upload_buffer orelse return error.PipelineMissingBuffer;

        upload_buffer.map();

        for (self.modules.items) |*module| {
            if (module.desc.type == .compute) {
                if (module.enabled == false) continue;
                const param_value = [_]f32{2.0}; // for testing
                const mapped = module.mapped_param_buf_slice orelse unreachable;
                @memcpy(mapped, &param_value);
            }
        }

        upload_buffer.unmap();
    }

    /// create nodes for each module
    fn runModulesCreateNodes(self: *Pipeline) !void {
        for (self.modules.items) |*module| {
            if (module.enabled == false) continue;
            if (module.desc.createNodes) |createNodesFn| {
                try createNodesFn(self, module);
            }
        }
    }

    /// Builds a DAG graph for the node by connecting nodes based on matching connector handles
    /// then performs a topological sort to determine execution order
    fn runNodesBuildExecutionOrder(self: *Pipeline) !void {
        // TODO: make this better, if there are lots of nodes, this is O(n^2)
        // first build the graph by connecting nodes based on matching connector handles
        var node_pool_handles_a = self.node_pool.liveHandles();
        while (node_pool_handles_a.next()) |node_handle_a| {
            var node_pool_handles_b = self.node_pool.liveHandles();
            while (node_pool_handles_b.next()) |node_handle_b| {
                // slog.debug("Checking for edge between node {any} and node {any}", .{ node_handle_a, node_handle_b });
                // skip if edge already exists
                if (self.node_graph.getEdge(node_handle_a, node_handle_b) != null) continue;
                if (self.node_graph.getEdge(node_handle_b, node_handle_a) != null) continue;
                if (node_handle_a.id == node_handle_b.id) continue;
                // NOTE: what we are about to do here is further constrain the node graph
                // by only allowing to connect nodes in the order they were created
                if (node_handle_a.id > node_handle_b.id) continue;
                // add nodes to graph
                try self.node_graph.add(node_handle_a);
                try self.node_graph.add(node_handle_b);
                // get connector handle
                const node_a = try self.node_pool.getPtr(node_handle_a);
                const node_b = try self.node_pool.getPtr(node_handle_b);
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
                    slog.debug("Adding edge from node {any} to node {any}", .{ node_handle_a, node_handle_b });
                    try self.node_graph.addEdge(node_handle_a, node_handle_b, match_handle.?);
                }
            }
        }
        var iter = try self.node_graph.topSortIterator();
        defer iter.deinit();
        while (try iter.next()) |value| {
            try self.node_execution_order.append(self.allocator, self.node_graph.lookup(value).?);
        }
        slog.debug("Topological sorted order: {any}", .{self.node_execution_order.items});
    }

    /// Allocates output textures and creates compute shaders for each node
    /// also creates bindings for each shader
    ///
    /// similar to vkdt dt_graph_run_nodes_allocate()
    fn runNodesInitConnectorTextures(self: *Pipeline) !void {
        const gpu_inst = self.gpu orelse return error.PipelineNoGPUInstance;
        for (self.node_execution_order.items) |node_handle| {
            const node = try self.node_pool.getPtr(node_handle);
            for (node.desc.sockets) |socket| {
                if (socket) |sock| {
                    if (sock.type.direction() == .output) {
                        const conn_handle = sock.private.conn_handle orelse return error.NodeOutputSocketMissingConnectorHandle;
                        // slog.debug("Allocating output texture for node socket {s} with connector handle {any}", .{ sock.name, conn_handle });
                        var buf: [256]u8 = undefined;
                        const str = try std.fmt.bufPrint(&buf, "id: {d}", .{conn_handle.id});
                        const texture = try gpu.Texture.init(gpu_inst, str, sock.format, sock.roi.?);
                        // defer texture.deinit();
                        // store texture in connector pool
                        const conn = try self.connector_pool.getPtr(conn_handle);
                        conn.* = texture;
                    }
                }
            }
        }
    }

    fn runNodesCreateBindings(self: *Pipeline) !void {
        const gpu_inst = self.gpu orelse return error.PipelineNoGPUInstance;
        for (self.node_execution_order.items) |node_handle| {
            const node = try self.node_pool.getPtr(node_handle);

            if (node.desc.type == .compute) {
                // CREATE DESCRIPTIONS
                // all sockets are on group 0
                var layout_group_0_binding: [gpu.MAX_BINDINGS]?gpu.BindGroupLayoutEntry = @splat(null);
                var bind_group_0_binds: [gpu.MAX_BINDINGS]?gpu.BindGroupEntry = @splat(null);
                for (node.desc.sockets, 0..) |socket, binding_number| {
                    if (socket) |sock| {
                        // prepare shader pipe connections
                        layout_group_0_binding[binding_number] = gpu.BindGroupLayoutEntry{
                            .texture = .{
                                .access = sock.type.toShaderPipeBindGroupLayoutEntryAccess(),
                                .format = sock.format,
                            },
                        };
                        slog.debug("Added bind group layout entry for binding {d}", .{binding_number});

                        const conn_handle = sock.private.conn_handle orelse return error.NodeOutputSocketMissingConnectorHandle;
                        const conn = try self.connector_pool.getPtr(conn_handle);
                        const texture = conn.* orelse return error.NodeSocketMissingConnectorTexture;
                        bind_group_0_binds[binding_number] = gpu.BindGroupEntry{
                            .texture = texture,
                        };
                    }
                }

                // params are on group 1
                var layout_group_1_binding: [gpu.MAX_BINDINGS]?gpu.BindGroupLayoutEntry = @splat(null);
                var bind_group_1_binds: [gpu.MAX_BINDINGS]?gpu.BindGroupEntry = @splat(null);
                if (node.*.mod.*.param_handle) |param_handle| {
                    const param_buffer = try self.param_buffer_pool.getPtr(param_handle);
                    const param_buf = param_buffer.* orelse return error.ModuleParamBufferNotAllocated;
                    layout_group_1_binding[0] = .{ .buffer = .{} };
                    bind_group_1_binds[0] = .{ .buffer = param_buf };
                }

                // CREATE SHADER PIPE AND BINDINGS
                slog.debug("Creating shader for node with entry point: {s}", .{node.desc.entry_point});
                var layout_group: [gpu.MAX_BIND_GROUPS]?[gpu.MAX_BINDINGS]?gpu.BindGroupLayoutEntry = @splat(null);
                layout_group[0] = layout_group_0_binding;
                layout_group[1] = layout_group_1_binding;
                const shader = try gpu.ShaderPipe.init(
                    gpu_inst,
                    node.desc.shader_code,
                    node.desc.entry_point,
                    layout_group,
                );
                node.shader = shader;

                slog.debug("Creating bindings for node with entry point: {s}", .{node.desc.entry_point});
                var bind_group: [gpu.MAX_BIND_GROUPS]?[gpu.MAX_BINDINGS]?gpu.BindGroupEntry = @splat(null);
                bind_group[0] = bind_group_0_binds;
                bind_group[1] = bind_group_1_binds;
                const bindings = try gpu.Bindings.init(gpu_inst, &shader, bind_group);
                // defer bindings.deinit();
                node.bindings = bindings;
            }
        }
    }

    fn runNodesAllocateUploadBufferForTextures(self: *Pipeline) !void {
        if (self.upload_fba) |*upload_fba| {
            // std.debug.print("Upload FBA: {any}\n", .{upload_fba});
            std.debug.print("Upload FBA end index before allocation: {d}\n", .{upload_fba.end_index});
            var upload_allocator = upload_fba.allocator();

            // we currently only support one upload in the entire pipeline
            // so we are going check if the first node has a source connector
            const first_node_handle = self.node_execution_order.items[0];
            var first_node_ptr = self.node_pool.getPtr(first_node_handle) catch unreachable;

            // TODO: support multiple source uploads in the future
            // TODO: find the correct input socket by type
            if (first_node_ptr.desc.sockets[0]) |*sock| {
                if (sock.type == .source) {
                    const size_bytes = sock.roi.?.w * sock.roi.?.h * sock.format.bpp();
                    slog.debug("Allocating upload buffer for textures for size {d} bytes", .{size_bytes});
                    const mapped_slice = try upload_allocator.alignedAlloc(u8, .@"16", size_bytes);

                    const upload_offset = @intFromPtr(mapped_slice.ptr) - @intFromPtr(upload_fba.buffer.ptr);
                    sock.*.private.staging_offset = upload_offset;
                    const mapped_slice_ptr: *anyopaque = @ptrCast(@alignCast(mapped_slice.ptr));
                    sock.*.private.staging = mapped_slice_ptr;
                } else {
                    slog.err("First node input socket is not of type source, skipping upload", .{});
                    return error.FirstNodeInputSocketNotSource;
                }
            }
        }

        // var download_fba = self.download_fba orelse return error.PipelineMissingBuffer;
        if (self.download_fba) |*download_fba| {
            var download_allocator = download_fba.allocator();
            // we currently only support one download in the entire pipeline
            // so we are going check if the last node has a sink connector

            const last_node_handle = self.node_execution_order.items[self.node_execution_order.items.len - 1];
            var last_node_ptr = try self.node_pool.getPtr(last_node_handle);

            if (last_node_ptr.desc.sockets[0]) |*sock| {
                if (sock.type == .sink) {
                    const size_bytes = sock.roi.?.w * sock.roi.?.h * sock.format.bpp();
                    slog.debug("Allocating download buffer at for size {d} bytes", .{size_bytes});
                    const mapped_slice = try download_allocator.alignedAlloc(u8, .@"16", size_bytes);

                    const download_offset = @intFromPtr(mapped_slice.ptr) - @intFromPtr(download_fba.buffer.ptr);
                    sock.*.private.staging_offset = download_offset;
                    const mapped_slice_ptr: *anyopaque = @ptrCast(@alignCast(mapped_slice.ptr));
                    sock.*.private.staging = mapped_slice_ptr;
                } else {
                    slog.err("Sink node socket is not of type sink, skipping download", .{});
                    return error.LastNodeInputSocketNotSource;
                }
            }
        }
    }

    /// Calls module readSource() functions to upload source data to GPU
    ///
    /// similar to vkdt dt_graph_run_nodes_upload()
    fn runNodesUploadSource(self: *Pipeline) !void {
        var upload_buffer = self.upload_buffer orelse return error.PipelineMissingBuffer;

        upload_buffer.map();

        // we currently only support one upload in the entire pipeline
        // so we are going check if the first node has a source connector
        const first_node_handle = self.node_execution_order.items[0];
        var first_node = self.node_pool.getPtr(first_node_handle) catch unreachable;

        // TODO: support multiple source uploads in the future
        // TODO: find the correct input socket by type
        if (first_node.desc.sockets[0]) |*sock| {
            if (sock.type == .source) {
                if (first_node.mod.desc.readSource) |readSourceFn| {
                    slog.debug("Uploading source data for first node", .{});
                    const mapped = sock.*.private.staging orelse unreachable;
                    slog.debug("Calling readSource function for first node", .{});
                    readSourceFn(self, first_node.mod, mapped) catch unreachable;
                } else {
                    slog.err("First node source module has no readSource function defined", .{});
                    return error.NodeMissingReadSourceFunction;
                }
            } else {
                slog.err("First node input socket is not of type source, skipping upload", .{});
                return error.FirstNodeInputSocketNotSource;
            }
        }

        upload_buffer.unmap();
    }

    fn runNodes(self: *Pipeline) !void {
        const gpu_inst = self.gpu orelse return error.PipelineNoGPUInstance;
        var upload_buffer = self.upload_buffer orelse return error.PipelineMissingBuffer;
        var download_buffer = self.download_buffer orelse return error.PipelineMissingBuffer;

        var encoder = try gpu.Encoder.start(gpu_inst);
        defer encoder.deinit();

        // enqueue each node in execution order
        for (self.node_execution_order.items) |node_handle| {
            const node = self.node_pool.getPtr(node_handle) catch unreachable;
            switch (node.desc.type) {
                .compute => {
                    if (node.*.mod.*.param_handle) |param_handle| {
                        const param_buffer = self.param_buffer_pool.getPtr(param_handle) catch unreachable;
                        var param_buf = param_buffer.* orelse return error.ModuleMissingParamBuffer;
                        const param_offset = node.*.mod.*.param_offset orelse return error.ModuleMissingParamBufferOffset;
                        slog.debug("Enqueueing param buffer at offset {d}", .{param_offset});
                        encoder.enqueueBufToBuf(&upload_buffer, param_offset, &param_buf, 0, @sizeOf(f32)) catch unreachable;
                    } else {
                        slog.err("Compute node's module has no param buffer handle", .{});
                        return error.ModuleMissingParamBuffer;
                    }
                    var shader = node.shader orelse return error.NodeMissingShader;
                    var bindings = node.bindings orelse return error.NodeMissingBindings;
                    slog.debug("Enqueueing compute shader for node {s}", .{node.desc.entry_point});
                    encoder.enqueueShader(
                        &shader,
                        &bindings,
                        node.desc.run_size.?,
                    );
                },
                .source => {
                    slog.debug("Enqueueing source node {s} buffer to texture copy", .{node.desc.entry_point});
                    const connector = self.connector_pool.getPtr(node.desc.sockets[0].?.private.conn_handle.?) catch unreachable;
                    var tex = connector.* orelse return error.PipelineMissingSourceNodeTexture;
                    const staging_offset = node.desc.sockets[0].?.private.staging_offset orelse unreachable;
                    const roi = node.desc.sockets[0].?.roi orelse unreachable;
                    slog.debug("Source node staging offset: {d}", .{staging_offset});
                    encoder.enqueueBufToTex(&upload_buffer, staging_offset, &tex, roi) catch unreachable;
                },
                .sink => {
                    slog.debug("Enqueueing sink node {s} texture to buffer copy", .{node.desc.entry_point});
                    const connector = self.connector_pool.getPtr(node.desc.sockets[0].?.private.conn_handle.?) catch unreachable;
                    var tex = connector.* orelse return error.PipelineMissingSinkNodeTexture;
                    const staging_offset = node.desc.sockets[0].?.private.staging_offset orelse unreachable;
                    slog.debug("Sink node staging offset: {d}", .{staging_offset});
                    const roi = node.desc.sockets[0].?.roi orelse unreachable;
                    encoder.enqueueTexToBuf(&download_buffer, staging_offset, &tex, roi) catch unreachable;
                },
            }
        }

        try gpu_inst.run(encoder.finish());
    }

    fn runNodesDownloadSink(self: *Pipeline) !void {
        var download_buffer = self.download_buffer orelse return error.PipelineMissingBuffer;

        download_buffer.map();

        // we currently only support one download in the entire pipeline
        // so we are going check if the last node has a sink connector
        const last_node_handle = self.node_execution_order.items[self.node_execution_order.items.len - 1];
        var last_node = try self.node_pool.getPtr(last_node_handle);

        slog.debug("Last node handle: {any}", .{last_node_handle});
        // slog.debug("Last node desc: {any}", .{last_node.desc});

        if (last_node.desc.sockets[0]) |*sock| {
            if (sock.type == .sink) {
                if (last_node.mod.desc.writeSink) |writeSinkFn| {
                    slog.debug("Downloading sink data for last node", .{});
                    const mapped = sock.*.private.staging orelse unreachable;
                    writeSinkFn(self, last_node.mod, mapped) catch unreachable;
                } else {
                    slog.err("Sink node has no writeSink function defined", .{});
                    return error.NodeMissingWriteSinkFunction;
                }
            } else {
                slog.err("Sink node socket is not of type sink, skipping download", .{});
                return error.LastNodeInputSocketNotSource;
            }
        }

        download_buffer.unmap();
    }
};
