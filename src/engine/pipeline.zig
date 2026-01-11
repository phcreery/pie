const std = @import("std");
const gpu = @import("gpu.zig");
const ROI = @import("ROI.zig");
const api = @import("modules/api.zig");
const print = @import("print.zig");
const Module = @import("Module.zig");
const Node = @import("Node.zig");
const Param = @import("Param.zig");
const HashMapPool = @import("pool_hash_map.zig").HashMapPool;
const DirectedGraph = @import("zig-graph/graph.zig").DirectedGraph;
const slog = std.log.scoped(.pipe);

pub const ModulePool = HashMapPool(Module);
pub const ModuleHandle = ModulePool.Handle;

pub const NodePool = HashMapPool(Node);
pub const NodeHandle = NodePool.Handle;

pub const ConnectorPool = HashMapPool(?gpu.Texture);
pub const ConnectorHandle = ConnectorPool.Handle;

pub const ParamBufferPool = HashMapPool(?gpu.Buffer);
pub const ParamBufferHandle = ParamBufferPool.Handle;

pub const PipelineConfig = struct {
    upload_buffer_size_bytes: ?usize = null,
    download_buffer_size_bytes: ?usize = null,
};

// TODO: history pool

/// The main pipeline structure that holds modules, nodes, and manages execution.
/// This is heavily inspired by vkdt.
///
/// The modules are put in a DAG, they they each create nodes which are put in
/// their own DAG, and then the nodes are executed in the order determined by the DAG.
///
/// A couple rules:
/// - Source modules must have a source output socket and no input socket
/// - Source modules must create a single source node
/// - Sink modules must have a sink input socket and no output socket
/// - Sink modules must create a single sink node
/// - Source nodes must be first in execution order. TODO: make any source node work
/// - Sink nodes must be last in execution order. TODO: make any sink node work
pub const Pipeline = struct {
    allocator: std.mem.Allocator,

    gpu: ?*gpu.GPU,

    upload_buffer: ?gpu.Buffer,
    upload_fba: ?gpu.Buffer.Allocator,

    download_buffer: ?gpu.Buffer,
    download_fba: ?gpu.Buffer.Allocator,

    module_pool: ModulePool,
    module_execution_order: std.ArrayList(ModuleHandle),

    node_pool: NodePool,
    node_execution_order: std.ArrayList(NodeHandle),

    connector_pool: ConnectorPool,

    param_buffer_pool: ParamBufferPool,

    rerouted: bool = true,
    dirty: bool = true,

    perf: PerfMetrics,

    pub const MAX_MODULES = 100;
    pub const MAX_NODES = 200;

    pub fn init(
        allocator: std.mem.Allocator,
        gpu_instance: ?*gpu.GPU,
        config: PipelineConfig,
    ) !Pipeline {
        if (gpu_instance == null) {
            slog.debug("No GPU instance provided, performing a dry run", .{});
        }
        var upload_buffer: ?gpu.Buffer = null;
        var upload_fba: ?gpu.Buffer.Allocator = null;
        var download_buffer: ?gpu.Buffer = null;
        var download_fba: ?gpu.Buffer.Allocator = null;
        if (gpu_instance) |gpu_inst| {
            upload_buffer = try gpu.Buffer.init(gpu_inst, config.upload_buffer_size_bytes, .upload);
            if (upload_buffer) |*ub| {
                upload_fba = try ub.fixedBufferAllocator();
                errdefer ub.deinit();
            }
            download_buffer = try gpu.Buffer.init(gpu_inst, config.download_buffer_size_bytes, .download);
            if (download_buffer) |*db| {
                download_fba = try db.fixedBufferAllocator();
                errdefer db.deinit();
            }
        } else {
            upload_buffer = null;
        }

        var module_pool = ModulePool.init(allocator);
        errdefer module_pool.deinit();

        var module_execution_order = std.ArrayList(ModuleHandle).initCapacity(allocator, 2) catch unreachable;
        errdefer module_execution_order.deinit(allocator);

        var node_pool = NodePool.init(allocator);
        errdefer node_pool.deinit();

        var node_execution_order = std.ArrayList(NodeHandle).initCapacity(allocator, 2) catch unreachable;
        errdefer node_execution_order.deinit(allocator);

        var connector_pool = ConnectorPool.init(allocator);
        errdefer connector_pool.deinit();

        var param_buffer_pool = ParamBufferPool.init(allocator);
        errdefer param_buffer_pool.deinit();

        return Pipeline{
            .allocator = allocator,
            .gpu = gpu_instance,

            .upload_buffer = upload_buffer,
            .upload_fba = upload_fba,

            .download_buffer = download_buffer,
            .download_fba = download_fba,

            .module_pool = module_pool,
            .module_execution_order = module_execution_order,

            .node_pool = node_pool,
            .node_execution_order = node_execution_order,

            .connector_pool = connector_pool,

            .param_buffer_pool = param_buffer_pool,

            .perf = try PerfMetrics.init(allocator),
        };
    }

    pub fn deinit(self: *Pipeline) void {
        slog.debug("De-initializing Pipeline", .{});
        // the pool deinit will take care of deallocating the textures
        self.module_pool.deinit();
        self.module_execution_order.deinit(self.allocator);
        self.node_execution_order.deinit(self.allocator);
        self.node_pool.deinit();
        self.connector_pool.deinit();
        self.param_buffer_pool.deinit();
        self.perf.deinit();

        if (self.upload_buffer) |*upload_buffer| {
            upload_buffer.deinit();
        }
        if (self.download_buffer) |*download_buffer| {
            download_buffer.deinit();
        }
    }

    // ================================================
    // Public Pipeline functions
    // ================================================

    pub fn addModule(self: *Pipeline, module_desc: api.ModuleDesc) !ModuleHandle {
        slog.debug("Adding module to pipeline: {s}", .{module_desc.name});
        const module = try Module.init(module_desc);
        self.rerouted = true;
        return try self.module_pool.add(module);
    }

    pub fn addNode(self: *Pipeline, mod_handle: ModuleHandle, node_desc: api.NodeDesc) !NodeHandle {
        slog.debug("Adding node to pipeline: {s}", .{node_desc.name});
        const node = try Node.init(self, mod_handle, node_desc);
        self.rerouted = true;
        return try self.node_pool.add(node);
    }

    pub fn connectModulesName(
        self: *Pipeline,
        src_mod: ModuleHandle,
        src_mod_socket_name: []const u8,
        dst_mod: ModuleHandle,
        dst_mod_socket_name: []const u8,
    ) !void {
        slog.debug("Connecting module {any} socket {s} to module {any} socket {s}", .{ src_mod, src_mod_socket_name, dst_mod, dst_mod_socket_name });
        var src_mod_ptr = self.module_pool.getPtr(src_mod) catch unreachable;
        var dst_mod_ptr = self.module_pool.getPtr(dst_mod) catch unreachable;

        slog.debug("Connecting module {s} socket {s} to module {s} socket {s}", .{ src_mod_ptr.desc.name, src_mod_socket_name, dst_mod_ptr.desc.name, dst_mod_socket_name });
        const dst_socket_idx = dst_mod_ptr.getSocketIndex(dst_mod_socket_name) orelse unreachable;
        const src_socket_idx = src_mod_ptr.getSocketIndex(src_mod_socket_name) orelse unreachable;

        dst_mod_ptr.desc.sockets[dst_socket_idx].?.private.connected_to_module = .{
            .item = src_mod,
            .socket_idx = src_socket_idx,
        };
        self.rerouted = true;
    }

    pub fn connectNodesName(
        self: *Pipeline,
        src_node: NodeHandle,
        src_node_socket_name: []const u8,
        dst_node: NodeHandle,
        dst_node_socket_name: []const u8,
    ) !void {
        slog.debug("Connecting node {any} socket {s} to node {any} socket {s}", .{ src_node, src_node_socket_name, dst_node, dst_node_socket_name });
        var src_node_ptr = self.node_pool.getPtr(src_node) catch unreachable;
        var dst_node_ptr = self.node_pool.getPtr(dst_node) catch unreachable;

        slog.debug("Connecting node {s} socket {s} to node {s} socket {s}", .{ src_node_ptr.desc.name, src_node_socket_name, dst_node_ptr.desc.name, dst_node_socket_name });
        const dst_socket_idx = dst_node_ptr.getSocketIndex(dst_node_socket_name) orelse unreachable;
        const src_socket_idx = src_node_ptr.getSocketIndex(src_node_socket_name) orelse unreachable;

        dst_node_ptr.desc.sockets[dst_socket_idx].?.private.connected_to_node = .{
            .item = src_node,
            .socket_idx = src_socket_idx,
        };
        self.rerouted = true;
    }

    pub fn copyConnector(
        self: *Pipeline,
        mod_handle: ModuleHandle,
        mod_socket_name: []const u8,
        node_handle: NodeHandle,
        node_socket_name: []const u8,
    ) !void {
        slog.debug("Connecting module {any} socket {s} to node {any} socket {s}", .{ node_handle, mod_socket_name, node_handle, node_socket_name });
        // TODO: some checks for socket compatibility

        var mod = self.module_pool.getPtr(mod_handle) catch unreachable;
        var node = self.node_pool.getPtr(node_handle) catch unreachable;

        const mod_socket_idx = mod.getSocketIndex(mod_socket_name) orelse unreachable;
        const node_socket_idx = node.getSocketIndex(node_socket_name) orelse unreachable;

        node.desc.sockets[node_socket_idx] = mod.desc.sockets[mod_socket_idx];

        // for input sockets on nodes
        if (node.desc.sockets[node_socket_idx].?.type.direction() == .input) {
            node.desc.sockets[node_socket_idx].?.private.associated_with_module = .{
                .item = mod_handle,
                .socket_idx = mod_socket_idx,
            };
        }

        // for output sockets on modules
        if (mod.desc.sockets[mod_socket_idx].?.type.direction() == .output) {
            mod.desc.sockets[mod_socket_idx].?.private.associated_with_node = .{
                .item = node_handle,
                .socket_idx = node_socket_idx,
            };
        }
        self.rerouted = true;
    }

    pub fn getModuleParamPtr(self: *Pipeline, mod_handle: ModuleHandle, param_name: []const u8) ?*api.Param {
        const mod = self.module_pool.getPtr(mod_handle) catch unreachable;
        return mod.getParamPtr(param_name);
    }

    pub fn setModuleParam(self: *Pipeline, mod_handle: ModuleHandle, param_name: []const u8, value: Param.ParamValue) !void {
        const mod = self.module_pool.getPtr(mod_handle) catch unreachable;
        const param = mod.getParamPtr(param_name) orelse unreachable;
        try param.value.set(value);
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

        self.perf.timerClear();
        try self.perf.timerStart();

        if (self.rerouted) {
            // First run modules so we know which nodes to create, what rois, buffers, and textures to allocate
            self.runModulesPreCheck() catch unreachable;

            self.runModulesCreateOutputConnectorHandles() catch unreachable;
            self.perf.timerLap("runModulesCreateOutputConnectorHandles") catch unreachable;
            self.runModulesBuildExecutionOrder() catch unreachable;
            self.perf.timerLap("runModulesBuildExecutionOrder") catch unreachable;

            self.runModulesCreateParamBufferHandles() catch unreachable;
            self.perf.timerLap("runModulesCreateParamBufferHandles") catch unreachable;
            self.runModulesModifyROIOut() catch unreachable;
            self.perf.timerLap("runModulesModifyROIOut") catch unreachable;
            self.runModulesInitParamBuffers() catch unreachable;
            self.perf.timerLap("runModulesInitParamBuffers") catch unreachable;
            self.runModulesAllocateUploadBufferForParams() catch unreachable;
            self.perf.timerLap("runModulesAllocateUploadBufferForParams") catch unreachable;

            self.runModulesCreateNodes() catch unreachable;
            self.perf.timerLap("runModulesCreateNodes") catch unreachable;
            // Then run nodes
            self.runNodesCreateOutputConnectorHandles() catch unreachable;
            self.perf.timerLap("runNodesCreateOutputConnectorHandles") catch unreachable;
            self.runNodesBuildExecutionOrder() catch unreachable;
            self.perf.timerLap("runNodesBuildExecutionOrder") catch unreachable;

            self.runNodesInitConnectorTextures() catch unreachable;
            self.perf.timerLap("runNodesInitConnectorTextures") catch unreachable;
            self.runNodesAllocateUploadBufferForTextures() catch unreachable;
            self.perf.timerLap("runNodesAllocateUploadBufferForTextures") catch unreachable;
            self.runNodesCreateBindings() catch unreachable;
            self.perf.timerLap("runNodesCreateBindings") catch unreachable;

            // TODO: clean up unused modules
            // TODO: clean up unused nodes

            self.rerouted = false;
            self.dirty = true;
        }

        // self.printPipeToStdout();

        if (self.dirty) {
            self.runModulesUploadParams() catch unreachable;
            self.perf.timerLap("runModulesUploadParams") catch unreachable;
            self.runNodesUploadSource() catch unreachable;
            self.perf.timerLap("runNodesUploadSource") catch unreachable;
            self.runNodes() catch unreachable;
            self.perf.timerLap("runNodes") catch unreachable;
            self.runNodesDownloadSink() catch unreachable;
            self.perf.timerLap("runNodesDownloadSink") catch unreachable;

            self.dirty = false;
        }

        // self.perf.uploadBuffer_size_bytes = if (self.upload_fba) |*upload_fba| upload_fba.size else 0;
        // self.perf.uploadBufferUsage_size_bytes = if (self.upload_fba) |*upload_fba| upload_fba.size - upload_fba.totalFreeSpace() else 0;
        // self.perf.downloadBuffer_size_bytes = if (self.download_fba) |*download_fba| download_fba.size else 0;
        // self.perf.downloadBufferUsage_size_bytes = if (self.download_fba) |*download_fba| download_fba.size - download_fba.totalFreeSpace() else 0;
        self.perf.recordUploadBufferUsage(self.upload_fba);
        self.perf.recordDownloadBufferUsage(self.download_fba);
        self.perf.countModules(&self.module_pool);
        self.perf.countNodes(&self.node_pool);
        self.perf.printReport();
    }

    // ================================================
    // Private Pipeline functions
    // ================================================

    /// pub for util printing purposes
    pub fn getNodeConnectorHandle(self: *Pipeline, socket: api.SocketDesc) ?ConnectorHandle {
        if (socket.private.connector_handle) |connector_handle| {
            return connector_handle;
        } else if (self.getConnectedNode(socket)) |connected_node_connection| {
            const connected_node = self.node_pool.getPtr(connected_node_connection.item) catch return null;
            const connected_node_socket = connected_node.desc.sockets[connected_node_connection.socket_idx] orelse return null;
            const connected_connector_handle = connected_node_socket.private.connector_handle orelse return null;
            return connected_connector_handle;
        }
        return null;
    }

    /// pub for debugging purposes
    pub fn getConnectedNode(pipe: *Pipeline, socket: api.SocketDesc) ?api.SocketConnection(NodeHandle) {
        if (socket.private.connected_to_node) |src_node_handle_connection| {
            return src_node_handle_connection;
        } else if (socket.private.associated_with_module) |assoc_mod_handle_connection| {
            // if the node is not directly connected to another node,
            // check if it is linked to a module then check what that
            // module is connected to and then traverse to the node that
            // is linked to that socket and connect to that node
            const assoc_mod = pipe.module_pool.getPtr(assoc_mod_handle_connection.item) catch unreachable;
            const assoc_mod_socket = assoc_mod.desc.sockets[assoc_mod_handle_connection.socket_idx] orelse unreachable;
            if (assoc_mod_socket.private.connected_to_module) |connected_to_mod_handle_connection| {
                const connected_to_mod = pipe.module_pool.getPtr(connected_to_mod_handle_connection.item) catch unreachable;
                const connected_to_mod_socket = connected_to_mod.desc.sockets[connected_to_mod_handle_connection.socket_idx] orelse unreachable;
                if (connected_to_mod_socket.private.associated_with_node) |src_node_handle_connection| {
                    return src_node_handle_connection;
                }
            }
        }
        return null;
    }

    pub fn printPipeToStdout(self: *Pipeline) void {
        print.printModules(self);
        print.printNodes(self);
        print.printNodes2(self) catch unreachable;
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
    fn runModulesCreateOutputConnectorHandles(self: *Pipeline) !void {
        // create connector handles for output sockets
        var mod_pool_handles = self.module_pool.liveHandles();
        while (mod_pool_handles.next()) |module_handle| {
            // for (self.module_execution_order.items) |module_handle| {
            var module = self.module_pool.getPtr(module_handle) catch unreachable;
            for (module.desc.sockets) |socket| {
                if (socket) |sock| {
                    if (sock.type.direction() == .output) {
                        var this_sock = module.getSocketPtr(sock.name) orelse unreachable;
                        slog.debug("Creating connector handle for module {s} output socket {s}", .{ module.desc.name, sock.name });
                        if (this_sock.private.connector_handle == null) {
                            this_sock.private.connector_handle = try self.connector_pool.add(null);
                        }
                    }
                }
            }
        }
    }

    // build execution order of modules based on DAG
    fn runModulesBuildExecutionOrder(self: *Pipeline) !void {
        // clear previous execution order
        self.module_execution_order.clearAndFree(self.allocator);

        // OPTION #1
        const ModuleGraph = DirectedGraph(ModuleHandle, ConnectorHandle, std.hash_map.AutoContext(ModuleHandle));
        var module_graph = ModuleGraph.init(self.allocator);
        defer module_graph.deinit();
        buildGraph(Module, &self.module_pool, &module_graph) catch unreachable;
        var iter = try module_graph.topSortIterator();
        defer iter.deinit();
        while (try iter.next()) |value| {
            try self.module_execution_order.append(self.allocator, module_graph.lookup(value).?);
        }

        // OPTION #2
        // var module_dag_iter = try PooledDagDfsIterator(Module).iterator(self.allocator, &self.module_pool);
        // defer module_dag_iter.deinit();
        // while (module_dag_iter.next()) |maybe_node_handle| {
        //     const node_handle = maybe_node_handle orelse break;
        //     try self.module_execution_order.append(self.allocator, node_handle);
        // } else |err| {
        //     slog.debug("Error during DAG traversal: {any}\n", .{err});
        // }
        slog.debug("Topological sorted order of modules: {any}", .{self.module_execution_order.items});
    }

    /// configure connectors only for module output connectors
    fn runModulesCreateParamBufferHandles(self: *Pipeline) !void {
        for (self.module_execution_order.items) |module_handle| {
            var module = self.module_pool.getPtr(module_handle) catch unreachable;
            // create params buffer
            const param_buffer_handle = try self.param_buffer_pool.add(null);
            module.param_handle = param_buffer_handle;
        }
    }

    fn runModulesModifyROIOut(self: *Pipeline) !void {
        for (self.module_execution_order.items) |module_handle| {
            const module = self.module_pool.getPtr(module_handle) catch unreachable;
            // set roi in based on connected module roi out
            for (module.desc.sockets) |socket| {
                if (socket) |sock| {
                    if (sock.type.direction() == .input) {
                        if (sock.private.connected_to_module) |connection| {
                            const connected_to_module = self.module_pool.getPtr(connection.item) catch unreachable;
                            var socket_ptr = module.getSocketPtr(sock.name) orelse unreachable;
                            slog.debug("Setting ROI for module {s} socket {s} from connected module {s}", .{ module.desc.name, sock.name, connected_to_module.desc.name });
                            const connected_to_socket = connected_to_module.desc.sockets[connection.socket_idx] orelse unreachable;
                            socket_ptr.roi = connected_to_socket.roi;
                        }
                    }
                }
            }

            // modify roi out
            if (module.desc.modifyROIOut) |modifyROIOutFn| {
                try modifyROIOutFn(self, module_handle);
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

            var size_bytes: usize = 0;
            if (module.desc.params) |params| {
                for (params) |param| {
                    if (param) |p| {
                        // size_bytes += @sizeOf(p.value);
                        size_bytes += p.value.size();
                    }
                }
            }

            const buffer = try gpu.Buffer.init(gpu_inst, size_bytes, .storage);
            // defer texture.deinit();
            // store texture in connector pool
            const param_buffer = try self.param_buffer_pool.getPtr(param_handle);
            param_buffer.* = buffer;
            module.param_size = size_bytes;
        }
    }

    fn runModulesAllocateUploadBufferForParams(self: *Pipeline) !void {
        if (self.upload_fba) |*upload_fba| {
            var upload_allocator = upload_fba.allocator();

            for (self.module_execution_order.items) |module_handle| {
                var module = self.module_pool.getPtr(module_handle) catch unreachable;
                if (module.desc.type == .compute) {
                    if (module.enabled == false) continue;
                    const size_bytes = module.param_size orelse return error.ModuleParamBufferSizeNotSet;
                    slog.debug("Allocating upload buffer for params for size {d} bytes", .{size_bytes});
                    const mapped_param_slice = try upload_allocator.alignedAlloc(u8, gpu.COPY_BUFFER_ALIGNMENT, size_bytes);

                    const param_offset = @intFromPtr(mapped_param_slice.ptr) - @intFromPtr(upload_fba.ptr);
                    const mapped_slice_ptr: *anyopaque = @ptrCast(@alignCast(mapped_param_slice.ptr));
                    module.mapped_param_slice_ptr = mapped_slice_ptr;

                    module.param_offset = param_offset;
                }
            }
        }
    }

    /// remove all existing nodes and
    /// create nodes for each module
    fn runModulesCreateNodes(self: *Pipeline) !void {
        var node_pool_handles = self.node_pool.liveHandles();
        while (node_pool_handles.next()) |node_handle| {
            self.node_pool.remove(node_handle);
        }

        for (self.module_execution_order.items) |module_handle| {
            const module = self.module_pool.getPtr(module_handle) catch unreachable;
            if (module.enabled == false) continue;
            if (module.desc.createNodes) |createNodesFn| {
                try createNodesFn(self, module_handle);
            }
        }
    }

    /// configure connectors only for module output connectors
    fn runNodesCreateOutputConnectorHandles(self: *Pipeline) !void {
        // create connector handles for output sockets
        var node_pool_handles = self.node_pool.liveHandles();
        while (node_pool_handles.next()) |node_handle| {
            // for (self.node_execution_order.items) |node_handle| {
            var node = self.node_pool.getPtr(node_handle) catch unreachable;
            for (node.desc.sockets) |socket| {
                if (socket) |sock| {
                    if (sock.type.direction() == .output) {
                        var this_sock = node.getSocketPtr(sock.name) orelse unreachable;
                        slog.debug("Creating connector handle for node {s} output socket {s}", .{ node.desc.name, sock.name });
                        if (this_sock.private.connector_handle == null) {
                            this_sock.private.connector_handle = try self.connector_pool.add(null);
                        }
                    }
                }
            }
        }
    }

    /// Builds a DAG graph for the node by connecting nodes based on connected_to_* and associated_with_* fields,
    /// then performs a topological sort to determine execution order
    fn runNodesBuildExecutionOrder(self: *Pipeline) !void {
        // flatten all meta connections first
        // right now, nodes are not directly connected to each other across modules
        // so we need to traverse the module connections to find the actual source node

        // ┌───────────┐                         ┌──────────────────────┐
        // │   mod1    <--- module connection ---<        mod2          │
        // │\┌───────┐/│                         │\┌───────┐  ┌───────┐/│
        // │ │ node1 │ │                         │ │ node2 <--< node3 │ │
        // │ └───────┘ │                         │ └───────┘  └───────┘ │
        // └───────────┘                         └──────────────────────┘
        //
        // will become
        //
        // ┌───────────┐                         ┌──────────────────────┐
        // │   mod1    <--- module connection ---<        mod2          │
        // │\┌───────┐/│                         │\┌───────┐  ┌───────┐/│
        // │ │ node1 <------ node connection ------< node2 <--< node3 │ │
        // │ └───────┘ │                         │ └───────┘  └───────┘ │
        // └───────────┘                         └──────────────────────┘

        var node_pool_handles = self.node_pool.liveHandles();
        while (node_pool_handles.next()) |dst_node_handle| {
            const dst_node = self.node_pool.getPtr(dst_node_handle) catch unreachable;
            for (&dst_node.desc.sockets) |*socket| {
                if (socket.*) |*sock| {
                    if (self.getConnectedNode(sock.*)) |src_node_handle_connection| {
                        sock.private.connected_to_node = src_node_handle_connection; // flatten meta connection
                    }
                }
            }
        }

        // clear previous execution order
        self.node_execution_order.clearAndFree(self.allocator);

        // OPTION #1
        const NodeGraph = DirectedGraph(NodeHandle, ConnectorHandle, std.hash_map.AutoContext(NodeHandle));
        var node_graph = NodeGraph.init(self.allocator);
        defer node_graph.deinit();
        buildGraph(Node, &self.node_pool, &node_graph) catch unreachable;
        var iter = try node_graph.topSortIterator();
        defer iter.deinit();
        while (try iter.next()) |value| {
            try self.node_execution_order.append(self.allocator, node_graph.lookup(value).?);
        }

        // OPTION #2
        // var node_dag_iter = try PooledDagDfsIterator(Node).iterator(self.allocator, &self.node_pool);
        // defer node_dag_iter.deinit();
        // while (node_dag_iter.next()) |maybe_node_handle| {
        //     const node_handle = maybe_node_handle orelse break;
        //     try self.node_execution_order.append(self.allocator, node_handle);
        // } else |err| {
        //     slog.debug("Error during DAG traversal: {any}\n", .{err});
        // }

        slog.debug("Topological sorted order of nodes: {any}", .{self.node_execution_order.items});
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
                        const connector_handle = self.getNodeConnectorHandle(sock) orelse return error.NodeOutputSocketMissingConnectorHandle;
                        // slog.debug("Allocating output texture for node socket {s} with connector handle {any}", .{ sock.name, connector_handle });
                        var buf: [256]u8 = undefined;
                        const str = try std.fmt.bufPrint(&buf, "id: {d}", .{connector_handle.id});
                        slog.debug("Allocating output texture for node socket {s} with connector handle {any}", .{ sock.name, connector_handle });
                        const texture = try gpu.Texture.init(gpu_inst, str, sock.format, sock.roi.?);
                        // defer texture.deinit();
                        // store texture in connector pool
                        const conn = try self.connector_pool.getPtr(connector_handle);
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

                // params are on group 0
                var layout_group_0_binding: [gpu.MAX_BINDINGS]?gpu.BindGroupLayoutEntry = @splat(null);
                var bind_group_0_binds: [gpu.MAX_BINDINGS]?gpu.BindGroupEntry = @splat(null);
                const mod = self.module_pool.getPtr(node.*.mod) catch unreachable;
                if (mod.*.param_handle) |param_handle| {
                    const param_buffer = try self.param_buffer_pool.getPtr(param_handle);
                    const param_buf = param_buffer.* orelse return error.ModuleParamBufferNotAllocated;
                    layout_group_0_binding[0] = .{ .buffer = .{} };
                    bind_group_0_binds[0] = .{ .buffer = param_buf };
                }

                // all sockets are on group 1
                var layout_group_1_binding: [gpu.MAX_BINDINGS]?gpu.BindGroupLayoutEntry = @splat(null);
                var bind_group_1_binds: [gpu.MAX_BINDINGS]?gpu.BindGroupEntry = @splat(null);
                for (node.desc.sockets, 0..) |socket, binding_number| {
                    if (socket) |sock| {
                        // prepare shader pipe connections
                        layout_group_1_binding[binding_number] = gpu.BindGroupLayoutEntry{
                            .texture = .{
                                .access = sock.type.toComputePipelineBindGroupLayoutEntryAccess(),
                                .format = sock.format,
                            },
                        };
                        slog.debug("Added bind group layout entry for binding {d}", .{binding_number});

                        const connector_handle = self.getNodeConnectorHandle(sock) orelse return error.NodeOutputSocketMissingConnectorHandle;
                        const conn = try self.connector_pool.getPtr(connector_handle);
                        const texture = conn.* orelse return error.NodeSocketMissingConnectorTexture;
                        bind_group_1_binds[binding_number] = gpu.BindGroupEntry{
                            .texture = texture,
                        };
                    }
                }

                // CREATE SHADER PIPE AND BINDINGS
                // ideally this would be done once on startup, but vkdt runs dt_graph_create_shader_module()
                // with the spirv code for each node every frame in dt_graph_run_nodes_allocate()
                slog.debug("Creating shader for node with entry point: {s}", .{node.desc.name});
                var layout_group: [gpu.MAX_BIND_GROUPS]?[gpu.MAX_BINDINGS]?gpu.BindGroupLayoutEntry = @splat(null);
                layout_group[0] = layout_group_0_binding;
                layout_group[1] = layout_group_1_binding;

                const shader = node.desc.shader orelse return error.NodeMissingShaderCode;
                const pipeline = try gpu.ComputePipeline.init(
                    gpu_inst,
                    shader,
                    "main",
                    layout_group,
                );
                node.compute_pipeline = pipeline;

                slog.debug("Creating bindings for node with entry point: {s}", .{node.desc.name});
                var bind_group: [gpu.MAX_BIND_GROUPS]?[gpu.MAX_BINDINGS]?gpu.BindGroupEntry = @splat(null);
                bind_group[0] = bind_group_0_binds;
                bind_group[1] = bind_group_1_binds;
                const bindings = try gpu.Bindings.init(gpu_inst, &pipeline, bind_group);
                // defer bindings.deinit();
                node.bindings = bindings;
            }
        }
    }

    fn runNodesAllocateUploadBufferForTextures(self: *Pipeline) !void {
        if (self.upload_fba) |*upload_fba| {
            var upload_allocator = upload_fba.allocator();

            // we currently only support one upload in the entire pipeline
            // so we are going check if the first node has a source connector
            const first_node_handle = self.node_execution_order.items[0];
            var first_node_ptr = self.node_pool.getPtr(first_node_handle) catch unreachable;

            slog.debug("First node: {s}", .{first_node_ptr.desc.name});

            // TODO: support multiple source uploads in the future
            // TODO: find the correct input socket by type
            if (first_node_ptr.desc.sockets[0]) |*sock| {
                if (sock.type == .source) {
                    const size_bytes = sock.roi.?.w * sock.roi.?.h * sock.format.bpp();
                    slog.debug("Allocating upload buffer for textures for size {d} bytes", .{size_bytes});
                    const mapped_slice = try upload_allocator.alignedAlloc(u8, gpu.COPY_BUFFER_ALIGNMENT, size_bytes);

                    const upload_offset = @intFromPtr(mapped_slice.ptr) - @intFromPtr(upload_fba.ptr);
                    sock.*.private.staging_offset = upload_offset;
                    const mapped_slice_ptr: *anyopaque = @ptrCast(@alignCast(mapped_slice.ptr));
                    sock.*.private.staging_ptr = mapped_slice_ptr;
                } else {
                    slog.err("First node only socket is not of type source, skipping upload", .{});
                    return error.FirstNodeInputSocketNotSource;
                }
            }
        }

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
                    const mapped_slice = try download_allocator.alignedAlloc(u8, gpu.COPY_BUFFER_ALIGNMENT, size_bytes);

                    const download_offset = @intFromPtr(mapped_slice.ptr) - @intFromPtr(download_fba.ptr);
                    sock.*.private.staging_offset = download_offset;
                    const mapped_slice_ptr: *anyopaque = @ptrCast(@alignCast(mapped_slice.ptr));
                    sock.*.private.staging_ptr = mapped_slice_ptr;
                } else {
                    slog.err("Sink node socket is not of type sink, skipping download", .{});
                    return error.LastNodeInputSocketNotSink;
                }
            }
        }
    }

    pub fn runModulesUploadParams(self: *Pipeline) !void {
        var upload_buffer = self.upload_buffer orelse return error.PipelineMissingBuffer;

        upload_buffer.map();

        for (self.module_execution_order.items) |module_handle| {
            const module = self.module_pool.getPtr(module_handle) catch unreachable;
            if (module.desc.type == .compute) {
                if (module.enabled == false) continue;

                var list = try std.ArrayList(u8).initCapacity(self.allocator, module.param_size orelse 0);
                defer list.deinit(self.allocator);

                // TODO: compute_byte_offset and length based on param types
                // this needs to follow the webgpu layout rules
                // currently we only support f32, u32, i32 types, so all alignment is 4 bytes

                // serialize params into byte array

                if (module.desc.params) |params| {
                    for (params) |param| {
                        if (param) |*p| {
                            const param_value_bytes = p.value.asBytes();
                            // TODO: ensure param_value_bytes.len == p.value.size()
                            try list.appendSlice(self.allocator, param_value_bytes);
                        }
                    }
                }

                slog.debug("Uploading params for module {s}, total size {d} bytes\n", .{ module.desc.name, list.items.len });
                // print hex array
                slog.debug("Param bytes for module {s}: \n", .{module.desc.name});
                var buf: [100]u8 = undefined;
                var w: std.io.Writer = .fixed(&buf);
                for (list.items) |byte| {
                    try w.print("{x:0>2} ", .{byte});
                }
                const printed = w.buffered();
                slog.debug("{s}\n", .{printed});

                const mapped_ptr: [*]u8 = @ptrCast(@alignCast(module.mapped_param_slice_ptr));
                @memcpy(mapped_ptr, list.items);
            }
        }

        upload_buffer.unmap();
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
                const first_node_mod = self.module_pool.getPtr(first_node.*.mod) catch unreachable;
                if (first_node_mod.desc.readSource) |readSourceFn| {
                    slog.debug("Uploading source data for first node", .{});
                    const mapped_ptr = sock.*.private.staging_ptr orelse unreachable;
                    slog.debug("Calling readSource function for first node", .{});
                    readSourceFn(self, first_node.*.mod, mapped_ptr) catch unreachable;
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
                    const mod = self.module_pool.getPtr(node.*.mod) catch unreachable;
                    if (mod.*.param_handle) |param_handle| {
                        const param_buffer = self.param_buffer_pool.getPtr(param_handle) catch unreachable;
                        var param_buf = param_buffer.* orelse return error.ModuleMissingParamBuffer;
                        const param_offset = mod.*.param_offset orelse return error.ModuleMissingParamBufferOffset;
                        const param_size_bytes = mod.*.param_size orelse return error.ModuleParamBufferSizeNotSet;
                        slog.debug("Enqueueing param buffer at offset {d}", .{param_offset});
                        encoder.enqueueBufToBuf(&upload_buffer, param_offset, &param_buf, 0, param_size_bytes) catch unreachable;
                    } else {
                        slog.err("Compute node's module has no param buffer handle", .{});
                        return error.ModuleMissingParamBuffer;
                    }
                    var compute_pipeline = node.compute_pipeline orelse return error.NodeMissingShader;
                    var bindings = node.bindings orelse return error.NodeMissingBindings;
                    slog.debug("Enqueueing compute shader for node {s}", .{node.desc.name});
                    encoder.enqueueShader(
                        &compute_pipeline,
                        &bindings,
                        node.desc.run_size.?,
                    );
                },
                .source => {
                    slog.debug("Enqueueing source node {s} buffer to texture copy", .{node.desc.name});
                    const connector_handle = self.getNodeConnectorHandle(node.desc.sockets[0].?) orelse return error.NodeOutputSocketMissingConnectorHandle;
                    const connector = self.connector_pool.getPtr(connector_handle) catch unreachable;
                    var tex = connector.* orelse return error.PipelineMissingSourceNodeTexture;
                    const staging_offset = node.desc.sockets[0].?.private.staging_offset orelse unreachable;
                    const roi = node.desc.sockets[0].?.roi orelse unreachable;
                    slog.debug("Source node staging offset: {d}", .{staging_offset});
                    encoder.enqueueBufToTex(&upload_buffer, staging_offset, &tex, roi) catch unreachable;
                },
                .sink => {
                    slog.debug("Enqueueing sink node {s} texture to buffer copy", .{node.desc.name});
                    const connector = self.connector_pool.getPtr(self.getNodeConnectorHandle(node.desc.sockets[0].?) orelse return error.NodeOutputSocketMissingConnectorHandle) catch unreachable;
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

        if (last_node.desc.sockets[0]) |*sock| {
            if (sock.type == .sink) {
                const last_node_mod = self.module_pool.getPtr(last_node.*.mod) catch unreachable;
                if (last_node_mod.desc.writeSink) |writeSinkFn| {
                    slog.debug("Downloading sink data for last node", .{});
                    const mapped_ptr = sock.*.private.staging_ptr orelse unreachable;
                    writeSinkFn(self, last_node.mod, mapped_ptr) catch unreachable;
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

/// stack-based DFS iterator for traversing DAGs stored in a HashMapPool
/// each element T must have a `desc` field in which there is a `sockets` field
/// each socket must have a `private.connected_to_node` field which is an optional connection to another node handle
pub fn PooledDagDfsIterator(T: type) type {
    return struct {
        pub fn iterator(allocator: std.mem.Allocator, pool: *HashMapPool(T)) !DagDfsIterator {
            // Map from `id` to `mark` value
            var mark = std.AutoHashMap(HashMapPool(T).Handle, u8).init(allocator);
            errdefer mark.deinit();

            // Stack to hold node IDs
            var stack = try std.ArrayList(HashMapPool(T).Handle).initCapacity(allocator, 1024);
            errdefer stack.deinit(allocator);
            var sp: isize = -1; // Stack pointer

            // Initialize mark map
            var pool_handles = pool.liveHandles();
            while (pool_handles.next()) |node_handle| {
                try mark.put(node_handle, 0);
            }

            // Initialize stack with all nodes that have no dependencies (sink nodes)
            pool_handles = pool.liveHandles();
            while (pool_handles.next()) |node_handle| {
                const node = pool.getPtr(node_handle) catch unreachable;
                for (node.desc.sockets) |socket| {
                    if (socket) |sock| {
                        if (sock.type == .sink) {
                            sp += 1;
                            try stack.insert(allocator, @as(usize, @intCast(sp)), node_handle);
                            try mark.put(node_handle, 1); // Mark as in-progress
                            break;
                        }
                    }
                }
            }

            return DagDfsIterator{
                .allocator = allocator,
                .stack = stack,
                .sp = sp,
                .mark = mark,
                .node_pool = pool,
            };
        }

        /// same as traverseDAG but iterative
        /// DagDfsIterator must deinit after use
        const DagDfsIterator = struct {
            allocator: std.mem.Allocator,
            stack: std.ArrayList(HashMapPool(T).Handle),
            sp: isize,
            mark: std.AutoHashMap(HashMapPool(T).Handle, u8),
            node_pool: *HashMapPool(T),

            pub fn deinit(it: *DagDfsIterator) void {
                it.stack.deinit(it.allocator);
                it.mark.deinit();
            }

            pub fn next(it: *DagDfsIterator) !?HashMapPool(T).Handle {
                if (it.sp < 0) {
                    return null;
                }
                while (it.sp >= 0) {
                    const curr_handle = it.stack.items[@as(usize, @intCast(it.sp))];
                    const curr_node = try it.node_pool.getPtr(curr_handle);
                    const curr_mark = it.mark.getPtr(curr_handle) orelse return error.Unreachable;
                    if (curr_mark.* == 1) {
                        // First time processing this node, push its children onto the stack
                        try it.mark.put(curr_handle, 2); // Pre-visit handling (mark as in-progress)
                        for (curr_node.desc.sockets) |child_socket| {
                            const socket = child_socket orelse continue;
                            const maybe_connected_to = if (comptime T == Node) socket.private.connected_to_node else if (comptime T == Module) socket.private.connected_to_module else unreachable;
                            const connected_to = maybe_connected_to orelse continue;
                            const child_node = connected_to.item;
                            const child_mark = it.mark.getPtr(child_node) orelse return error.Unreachable;
                            if (child_mark.* == 0) { // If child is unvisited
                                it.sp += 1;
                                try it.stack.insert(it.allocator, @as(usize, @intCast(it.sp)), child_node);
                                try it.mark.put(child_node, 1); // Mark as in-progress
                            }
                        }
                    } else {
                        // All children have been processed, post-visit handling
                        try it.mark.put(curr_handle, 3); // Mark as finished
                        it.sp -= 1; // Pop the current node off the stack
                        // Process currNode here (e.g., print or store in result list)
                        return curr_handle;
                    }
                }
                return null;
            }
        };
    };
}

/// Builds a DAG graph for the node by connecting nodes based on connected_to_* and associated_with_* fields,
/// then performs a topological sort to determine execution order
/// this used to be the default way to build the execution order for modules/nodes
pub fn buildGraph(
    T: type,
    pool: *HashMapPool(T),
    graph: *DirectedGraph(HashMapPool(T).Handle, ConnectorHandle, std.hash_map.AutoContext(HashMapPool(T).Handle)),
) !void {
    //  NOTE: this is better then check over each possible connection like I was doing,
    // but vkdt uses the connected_mi and associated_i fields to build the graph AND perform the DFS traversal
    // const Graph = DirectedGraph(HashMapPool(T).Handle, ConnectorHandle, std.hash_map.AutoContext(HashMapPool(T).Handle));
    // var graph = Graph.init(allocator);

    var pool_handles = pool.liveHandles();
    while (pool_handles.next()) |dst_node_handle| {
        const dst_node = pool.getPtr(dst_node_handle) catch unreachable;
        try graph.add(dst_node_handle);
        for (dst_node.desc.sockets) |socket| {
            if (socket) |sock| {
                // if (self.getConnectedNode(sock.*)) |src_node_handle_connection| {
                const maybe_connected_to = if (comptime T == Node) sock.private.connected_to_node else if (comptime T == Module) sock.private.connected_to_module else unreachable;
                const src_node_handle_connection = maybe_connected_to orelse continue;
                const src_node_handle = src_node_handle_connection.item;
                // connect
                try graph.add(src_node_handle);
                const src_node = pool.getPtr(src_node_handle) catch unreachable;
                const src_node_sock = src_node.desc.sockets[src_node_handle_connection.socket_idx] orelse unreachable;
                const connector_handle = src_node_sock.private.connector_handle orelse unreachable; // self.getNodeConnectorHandle(src_node_sock) ;
                try graph.addEdge(src_node_handle, dst_node_handle, connector_handle);
                // }
            }
        }
    }
}

pub const PerfMetrics = struct {
    allocator: std.mem.Allocator,

    timer: std.time.Timer,
    keys: std.ArrayList([]const u8),
    times: std.StringHashMap(u64),

    uploadBuffer_size_bytes: ?usize,
    uploadBufferUsage_size_bytes: ?usize,
    downloadBuffer_size_bytes: ?usize,
    downloadBufferUsage_size_bytes: ?usize,

    number_of_modules: ?usize,
    number_of_nodes: ?usize,

    const Self = @This();

    fn init(allocator: std.mem.Allocator) !PerfMetrics {
        return PerfMetrics{
            .allocator = allocator,
            .timer = undefined,
            .keys = try std.ArrayList([]const u8).initCapacity(allocator, 16),
            .times = std.StringHashMap(u64).init(allocator),
            .uploadBuffer_size_bytes = null,
            .uploadBufferUsage_size_bytes = null,
            .downloadBuffer_size_bytes = null,
            .downloadBufferUsage_size_bytes = null,
            .number_of_modules = null,
            .number_of_nodes = null,
        };
    }

    fn deinit(self: *PerfMetrics) void {
        self.times.deinit();
        self.keys.deinit(self.allocator);
    }

    /// TIMER
    fn timerStart(self: *PerfMetrics) !void {
        self.timer = try std.time.Timer.start();
    }

    fn timerLap(self: *PerfMetrics, name: []const u8) !void {
        const elapsed_ns = self.timer.lap();
        _ = try self.times.put(name, elapsed_ns);
        try self.keys.append(self.allocator, name);
        self.timer.reset();
    }

    fn timerClear(self: *PerfMetrics) void {
        self.timer.reset();
        self.keys.clearAndFree(self.allocator);
        self.times.clearAndFree();
    }

    /// BUFFER
    fn recordUploadBufferUsage(self: *PerfMetrics, upload_fba: ?gpu.Buffer.Allocator) void {
        self.uploadBuffer_size_bytes = if (upload_fba) |*fba| fba.size else 0;
        self.uploadBufferUsage_size_bytes = if (upload_fba) |*fba| fba.size - fba.totalFreeSpace() else 0;
    }
    fn recordDownloadBufferUsage(self: *PerfMetrics, download_fba: ?gpu.Buffer.Allocator) void {
        self.downloadBuffer_size_bytes = if (download_fba) |*fba| fba.size else 0;
        self.downloadBufferUsage_size_bytes = if (download_fba) |*fba| fba.size - fba.totalFreeSpace() else 0;
    }

    /// POOL
    fn countModules(self: *PerfMetrics, module_pool: *ModulePool) void {
        if (self.number_of_modules == null) {
            self.number_of_modules = 0;
        }
        var mod_pool_handles = module_pool.liveHandles();
        while (mod_pool_handles.next()) |_| {
            self.number_of_modules.? += 1;
        }
    }

    fn countNodes(self: *PerfMetrics, node_pool: *NodePool) void {
        if (self.number_of_nodes == null) {
            self.number_of_nodes = 0;
        }
        var node_pool_handles = node_pool.liveHandles();
        while (node_pool_handles.next()) |_| {
            self.number_of_nodes.? += 1;
        }
    }

    fn printReport(self: *PerfMetrics) void {
        // const printFn = std.debug.print;
        const printFn = slog.info;

        var total_time_ns: f64 = 0;

        var it = self.times.iterator();
        while (it.next()) |entry| {
            total_time_ns += @as(f64, @floatFromInt(entry.value_ptr.*));
        }

        printFn("Pipeline Performance Report:", .{});
        for (self.keys.items) |key| {
            const entry = self.times.getPtr(key) orelse continue;
            printFn(" {d: >5.2}% {d: >5.2} ms {s}", .{
                @as(f64, @floatFromInt(entry.*)) / total_time_ns * 100.0,
                @as(f64, @floatFromInt(entry.*)) / std.time.ns_per_ms,
                key,
            });
        }
        printFn(" Total time: {d} ms", .{total_time_ns / std.time.ns_per_ms});

        const uploadBufferUsage_size_bytes = self.uploadBufferUsage_size_bytes orelse 0;
        const uploadBuffer_size_bytes = self.uploadBuffer_size_bytes orelse 0;
        const downloadBufferUsage_size_bytes = self.downloadBufferUsage_size_bytes orelse 0;
        const downloadBuffer_size_bytes = self.downloadBuffer_size_bytes orelse 0;
        printFn(" {d: >5.2}% {B:.2}/{B:.2} {s}", .{
            @as(f64, @floatFromInt(uploadBufferUsage_size_bytes)) / @as(f64, @floatFromInt(uploadBuffer_size_bytes)) * 100.0,
            uploadBufferUsage_size_bytes,
            uploadBuffer_size_bytes,
            "uploadBuffer_size_bytes",
        });
        printFn(" {d: >5.2}% {B:.2}/{B:.2} {s}", .{
            @as(f64, @floatFromInt(downloadBufferUsage_size_bytes)) / @as(f64, @floatFromInt(downloadBuffer_size_bytes)) * 100.0,
            downloadBufferUsage_size_bytes,
            downloadBuffer_size_bytes,
            "downloadBuffer_size_bytes",
        });

        const number_of_modules = self.number_of_modules orelse 0;
        const number_of_nodes = self.number_of_nodes orelse 0;
        printFn(" {d} modules", .{number_of_modules});
        printFn(" {d} nodes", .{number_of_nodes});
    }
};
