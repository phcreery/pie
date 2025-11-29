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

const ModulePool = HashMapPool(Module);
pub const ModuleHandle = ModulePool.Handle;

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

    module_pool: ModulePool,

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

        const module_pool = ModulePool.init(allocator);
        errdefer module_pool.deinit();

        const node_pool = NodePool.init(allocator);
        errdefer node_pool.deinit();

        const NodeGraph = DirectedGraph(NodeHandle, ConnectorHandle, std.hash_map.AutoContext(NodeHandle));
        var node_graph = NodeGraph.init(allocator);
        errdefer node_graph.deinit();

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

            .module_pool = module_pool,

            .node_pool = node_pool,
            .node_graph = node_graph,
            .node_execution_order = node_execution_order,

            .connector_pool = connector_pool,

            .param_buffer_pool = param_buffer_pool,
        };
    }

    pub fn deinit(self: *Pipeline) void {
        slog.debug("De-initializing Pipeline", .{});
        // the pool deinit will take care of deallocating the textures
        self.module_pool.deinit();
        self.node_execution_order.deinit(self.allocator);
        self.node_graph.deinit();
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

    pub fn addModule(self: *Pipeline, module_desc: api.ModuleDesc) !ModuleHandle {
        slog.debug("Adding module to pipeline: {s}", .{module_desc.name});
        const module = try Module.init(module_desc);
        return try self.module_pool.add(module);
    }

    pub fn addNode(self: *Pipeline, mod: *Module, node_desc: api.NodeDesc) !NodeHandle {
        slog.debug("Adding node to pipeline: {s}", .{node_desc.entry_point});
        const node = try Node.init(self, mod, node_desc);
        return try self.node_pool.add(node);
    }

    pub fn copyConnector(
        self: *Pipeline,
        mod: *Module,
        // mod_handle: ModuleHandle,
        mod_socket_name: []const u8,
        node_handle: NodeHandle,
        node_socket_name: []const u8,
    ) !void {
        slog.debug("Connecting module {s} socket {s} to node {any} socket {s}", .{ mod.desc.name, mod_socket_name, node_handle, node_socket_name });
        // TODO: some checks for socket compatibility

        // var mod = self.module_pool.getPtr(mod_handle) catch unreachable;
        var node = self.node_pool.getPtr(node_handle) catch unreachable;

        const mod_socket_idx = mod.getSocketIndex(mod_socket_name) orelse unreachable;
        const node_socket_idx = node.getSocketIndex(node_socket_name) orelse unreachable;

        // node.desc.sockets[node_socket_idx].?.private.conn_handle = module_socket.private.conn_handle;

        node.desc.sockets[node_socket_idx] = mod.desc.sockets[mod_socket_idx];
        // for input sockets on nodes
        if (node.desc.sockets[node_socket_idx].?.type.direction() == .input) {
            // node.desc.sockets[node_socket_idx].?.private.associated_with_module = mod;
            // node.desc.sockets[node_socket_idx].?.private.associated_with_module_socket_idx = mod_socket_idx;
            node.desc.sockets[node_socket_idx].?.private.associated_with_module = .{
                .item = mod,
                .socket_idx = mod_socket_idx,
            };
        }

        // for output sockets on modules
        if (mod.desc.sockets[mod_socket_idx].?.type.direction() == .output) {
            // mod.desc.sockets[mod_socket_idx].?.private.associated_with_node = node_handle;
            // mod.desc.sockets[mod_socket_idx].?.private.associated_with_node_socket_idx = node_socket_idx;
            mod.desc.sockets[mod_socket_idx].?.private.associated_with_node = .{
                .item = node_handle,
                .socket_idx = node_socket_idx,
            };
        }
    }

    // pub fn connectNodes(
    //     self: *Pipeline,
    //     src_node_handle: NodeHandle,
    //     src_node_socket_name: []const u8,
    //     dst_node_handle: NodeHandle,
    //     dst_node_socket_name: []const u8,
    // ) !void {
    //     slog.debug("Connecting node {any} socket {s} to node {any} socket {s}", .{ src_node_handle, src_node_socket_name, dst_node_handle, dst_node_socket_name });
    // TODO: check input connection to mach previous node output connection

    // }

    pub fn connectModules(
        self: *Pipeline,
        // src_mod_ptr: *Module,
        src_mod: ModuleHandle,
        src_mod_socket_name: []const u8,
        // dst_mod_ptr: *Module,
        dst_mod: ModuleHandle,
        dst_mod_socket_name: []const u8,
    ) !void {
        slog.debug("Connecting module {any} socket {s} to module {any} socket {s}", .{ src_mod, src_mod_socket_name, dst_mod, dst_mod_socket_name });
        var src_mod_ptr = self.module_pool.getPtr(src_mod) catch unreachable;
        var dst_mod_ptr = self.module_pool.getPtr(dst_mod) catch unreachable;

        slog.debug("Connecting module {s} socket {s} to module {s} socket {s}", .{ src_mod_ptr.desc.name, src_mod_socket_name, dst_mod_ptr.desc.name, dst_mod_socket_name });
        const dst_socket_idx = dst_mod_ptr.getSocketIndex(dst_mod_socket_name) orelse unreachable;
        const src_socket_idx = src_mod_ptr.getSocketIndex(src_mod_socket_name) orelse unreachable;

        // dst_mod.desc.sockets[dst_socket_idx] = src_mod.desc.sockets[src_socket_idx];
        // dst_mod.desc.sockets[dst_socket_idx].?.format = src_mod.desc.sockets[src_socket_idx].?.format;
        // dst_mod_ptr.desc.sockets[dst_socket_idx].?.private.connected_to_module = src_mod_ptr;
        // dst_mod_ptr.desc.sockets[dst_socket_idx].?.private.connected_to_module_socket_idx = src_socket_idx;
        dst_mod_ptr.desc.sockets[dst_socket_idx].?.private.connected_to_module = .{
            .item = src_mod_ptr,
            .socket_idx = src_socket_idx,
        };
    }

    pub fn run(self: *Pipeline) !void {

        // Order of Operations:
        // dt_graph_run_modules
        // - modify_roi_out
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
        // self.runModulesModifyROIOut() catch unreachable;
        self.runModulesCreateConnectorHandles() catch unreachable;
        self.runModulesBuildExecutionOrder() catch unreachable;

        self.runModulesInitParamBuffers() catch unreachable;
        self.runModulesAllocateUploadBufferForParams() catch unreachable;
        self.runModulesCreateNodes() catch unreachable;

        // Then run nodes
        self.runNodesBuildExecutionOrder() catch unreachable;
        // TODO: put these all in a single loop after building execution order
        self.runNodesInitConnectorTextures() catch unreachable;

        // util.printNodes(self);
        // util.printNodes2(self) catch unreachable;

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
        var mod_pool_handles = self.module_pool.liveHandles();
        while (mod_pool_handles.next()) |module_handle| {
            var module = self.module_pool.getPtr(module_handle) catch unreachable;
            if (module.desc.type == .source) {
                const input_socket = module.getSocketPtr("input");
                if (input_socket != null) {
                    slog.err("Source module {s} has an input socket defined", .{module.desc.name});
                    return error.ModuleSourceHasInputSocket;
                }
            }
            if (module.desc.type == .compute) {
                const input_socket = module.getSocketPtr("input");
                if (input_socket == null) {
                    slog.err("Compute module {s} has no input socket defined", .{module.desc.name});
                    return error.ModuleComputeMissingInputSocket;
                }
                const output_socket = module.getSocketPtr("output");
                if (output_socket == null) {
                    slog.err("Compute module {s} has no output socket defined", .{module.desc.name});
                    return error.ModuleComputeMissingOutputSocket;
                }
            }
        }
    }

    /// configure connectors only for module output connectors
    fn runModulesCreateConnectorHandles(self: *Pipeline) !void {
        // create connector handles for output sockets
        var mod_pool_handles = self.module_pool.liveHandles();
        while (mod_pool_handles.next()) |module_handle| {
            var module = self.module_pool.getPtr(module_handle) catch unreachable;
            for (module.desc.sockets) |socket| {
                if (socket) |sock| {
                    if (sock.type.direction() == .output) {
                        var this_sock = module.getSocketPtr(sock.name) orelse unreachable;
                        slog.debug("Creating connector handle for module {s} output socket {s}", .{ module.desc.name, sock.name });
                        this_sock.private.conn_handle = try self.connector_pool.add(null);
                    }
                }
            }
        }
    }

    fn runModulesBuildExecutionOrder(self: *Pipeline) !void {
        // build execution order
        // const ModuleGraph = DirectedGraph(ModuleHandle, ConnectorHandle, std.hash_map.AutoContext(ModuleHandle));
        const ModuleGraph = DirectedGraph(*Module, ConnectorHandle, std.hash_map.AutoContext(*Module));
        var module_graph = ModuleGraph.init(self.allocator);
        defer module_graph.deinit();

        var mod_pool_handles = self.module_pool.liveHandles();
        while (mod_pool_handles.next()) |dst_mod_handle| {
            var dst_mod = self.module_pool.getPtr(dst_mod_handle) catch unreachable;
            if (dst_mod.enabled == false) continue;
            try module_graph.add(dst_mod);
            for (dst_mod.desc.sockets) |socket| {
                if (socket) |sock| {
                    if (sock.private.connected_to_module) |src_connection| {
                        const src_mod = src_connection.item;
                        try module_graph.add(src_mod);
                        // const src_mod = self.module_pool.getPtr(src_mod) catch unreachable;

                        slog.debug("Adding edge from module {s} to module {s}", .{ src_mod.desc.name, dst_mod.desc.name });
                        // const src_mod_sock_idx = sock.private.connected_to_module_socket_idx orelse unreachable;
                        const src_mod_sock = src_mod.desc.sockets[src_connection.socket_idx] orelse unreachable;
                        var dst_mod_sock = dst_mod.getSocketPtr(sock.name) orelse return error.ModuleMissingInputSock;

                        // connect
                        // TODO: check output connectors before configuring

                        dst_mod_sock.private.conn_handle = src_mod_sock.private.conn_handle;
                        try module_graph.addEdge(src_mod, dst_mod, src_mod_sock.private.conn_handle orelse unreachable);
                    }
                }
            }

            // create params buffer
            const param_buffer = try self.param_buffer_pool.add(null);
            dst_mod.param_handle = param_buffer;
            dst_mod.param_offset = 0;
            dst_mod.param_size = 0;
        }

        var module_execution_order = std.ArrayList(*Module).initCapacity(self.allocator, 2) catch unreachable;
        defer module_execution_order.deinit(self.allocator);

        var iter = try module_graph.topSortIterator();
        defer iter.deinit();
        while (try iter.next()) |value| {
            try module_execution_order.append(self.allocator, module_graph.lookup(value).?);
            // try module_execution_order.append(self.allocator, value);
        }
        // slog.debug("Topological sorted order of modules: {any}", .{module_execution_order.items});
        for (module_execution_order.items) |module| {
            slog.debug("Module in execution order: {s}", .{module.desc.name});
        }

        for (module_execution_order.items) |module| {
            // set roi in based on connected module roi out
            for (module.desc.sockets) |socket| {
                if (socket) |sock| {
                    if (sock.type.direction() == .input) {
                        if (sock.private.connected_to_module) |connected_to_module| {
                            var socket_ptr = module.getSocketPtr(sock.name) orelse unreachable;
                            slog.debug("Setting ROI for module {s} socket {s} from connected module {s}", .{ module.desc.name, sock.name, connected_to_module.item.desc.name });
                            const connected_to_socket = connected_to_module.item.desc.sockets[connected_to_module.socket_idx] orelse unreachable;
                            socket_ptr.roi = connected_to_socket.roi;
                        }
                    }
                }
            }

            // modify roi out
            if (module.desc.modifyROIOut) |modifyROIOutFn| {
                try modifyROIOutFn(self, module);
            } else {
                // auto propagate roi from input to output
                if (module.desc.type != .source and module.desc.type != .sink) {
                    const input_socket = module.getSocketPtr("input") orelse return error.ModuleNoROIFnMissingInputSock;
                    const output_socket = module.getSocketPtr("output") orelse return error.ModuleNoROIFnMissingOutputSock;
                    output_socket.roi = input_socket.roi;
                }
            }
        }
    }

    fn runModulesInitParamBuffers(self: *Pipeline) !void {
        const gpu_inst = self.gpu orelse return error.PipelineNoGPUInstance;
        var mod_pool_handles = self.module_pool.liveHandles();
        while (mod_pool_handles.next()) |module_handle| {
            const module = self.module_pool.getPtr(module_handle) catch unreachable;
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

            var mod_pool_handles = self.module_pool.liveHandles();
            while (mod_pool_handles.next()) |module_handle| {
                var module = self.module_pool.getPtr(module_handle) catch unreachable;
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

        var mod_pool_handles = self.module_pool.liveHandles();
        while (mod_pool_handles.next()) |module_handle| {
            const module = self.module_pool.getPtr(module_handle) catch unreachable;
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
        var mod_pool_handles = self.module_pool.liveHandles();
        while (mod_pool_handles.next()) |module_handle| {
            const module = self.module_pool.getPtr(module_handle) catch unreachable;
            if (module.enabled == false) continue;
            if (module.desc.createNodes) |createNodesFn| {
                try createNodesFn(self, module);
            }
        }
    }

    /// Builds a DAG graph for the node by connecting nodes based on connected_to_* and associated_with_* fields,
    /// then performs a topological sort to determine execution order
    fn runNodesBuildExecutionOrder(self: *Pipeline) !void {
        // NOTE: this is better then check over each possible connection like I was doing,
        // but vkdt uses the connected_mi and associated_i fields to build the graph AND perform the DFS traversal
        std.debug.print("\n", .{});
        slog.debug("Building node execution order", .{});
        var node_pool_handles = self.node_pool.liveHandles();
        while (node_pool_handles.next()) |dst_node_handle| {
            var dst_node = self.node_pool.getPtr(dst_node_handle) catch unreachable;
            try self.node_graph.add(dst_node_handle);
            for (dst_node.desc.sockets) |socket| {
                if (socket) |sock| {
                    var dst_node_sock = dst_node.getSocketPtr(sock.name) orelse return error.ModuleMissingInputSock;
                    if (sock.getConnectedNode()) |src_node_handle_connection| {
                        const src_node_handle = src_node_handle_connection.item;
                        // connect
                        try self.node_graph.add(src_node_handle);
                        const src_node = self.node_pool.getPtr(src_node_handle) catch unreachable;
                        slog.debug("Adding edge from node {s} to node {s}", .{ src_node.desc.entry_point, dst_node.desc.entry_point });
                        const src_node_sock = src_node.desc.sockets[src_node_handle_connection.socket_idx] orelse unreachable;
                        dst_node_sock.private.conn_handle = src_node_sock.private.conn_handle;
                        try self.node_graph.addEdge(src_node_handle, dst_node_handle, src_node_sock.private.conn_handle orelse unreachable);
                    }
                }
            }
        }

        var iter = try self.node_graph.topSortIterator();
        defer iter.deinit();
        while (try iter.next()) |value| {
            try self.node_execution_order.append(self.allocator, self.node_graph.lookup(value).?);
        }
        slog.debug("Topological sorted order of nodes: {any}", .{self.node_execution_order.items});
        std.debug.print("\n", .{});
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
                        slog.debug("Allocating output texture for node socket {s} with connector handle {any}", .{ sock.name, conn_handle });
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

            slog.debug("First node: {s}", .{first_node_ptr.desc.entry_point});

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
                    slog.err("First node only socket is not of type source, skipping upload", .{});
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
