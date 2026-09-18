const std = @import("std");
const gpu = @import("gpu/root.zig");
const ROI = @import("ROI.zig");
const api = @import("modules/api.zig");
const print = @import("pipeline_print.zig");
const perf = @import("pipeline_perf.zig");
const Module = @import("Module.zig");
const Node = @import("Node.zig");
const Socket = @import("Socket.zig");
const Connector = @import("Connector.zig");
const Param = @import("Param.zig");
const ImgParam = @import("ImgParam.zig");
const Modules = @import("modules/modules.zig");
const Pool = @import("pool.zig").Pool;
const PipelineHistory = @import("pipeline_history.zig").PipelineHistory;
const DirectedGraph = @import("zig-graph/graph.zig").DirectedGraph;
const slog = std.log.scoped(.pipe);

// TYPES

pub const ModulePool = Pool(Module);
pub const ModuleHandle = ModulePool.Handle;

pub const NodePool = Pool(Node);
pub const NodeHandle = NodePool.Handle;

pub const ConnectorHandle = Socket.SocketConnection;

pub const ParamBufferPool = Pool(?gpu.Buffer);
pub const ParamBufferHandle = ParamBufferPool.Handle;

// CONFIG

pub const PipelineConfig = struct {
    upload_buffer_size_bytes: ?usize = 75e6,
    download_buffer_size_bytes: ?usize = 75e6,
};

pub const MAX_MODULES = 100;
pub const MAX_NODES = 200;
pub const MAX_CONNECTORS = 500;

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
    io: std.Io,

    gpu: ?*gpu.GPU,

    upload_buffer: ?gpu.Buffer,
    upload_fba: ?gpu.Buffer.Allocator,

    download_buffer: ?gpu.Buffer,
    download_fba: ?gpu.Buffer.Allocator,

    module_pool: ModulePool,
    module_name_map: std.StringHashMap(ModuleHandle), // stored as name:id, ex. "i-raw:01"
    module_execution_order: std.ArrayList(ModuleHandle),

    repo: Modules.Repository,

    node_pool: NodePool,
    node_execution_order: std.ArrayList(NodeHandle),

    // connector_pool: ConnectorPool,

    param_buffer_pool: ParamBufferPool,

    rerouted: bool = true,
    dirty: bool = true,

    history: PipelineHistory,

    run_arena: std.heap.ArenaAllocator,

    perf: perf.PerfMetrics,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        gpu_instance: ?*gpu.GPU,
        user_config: ?PipelineConfig,
    ) !Pipeline {
        if (gpu_instance == null) {
            slog.debug("No GPU instance provided, performing a dry run", .{});
        }
        const config: PipelineConfig = user_config orelse .{};
        var upload_buffer: ?gpu.Buffer = null;
        var upload_fba: ?gpu.Buffer.Allocator = null;
        var download_buffer: ?gpu.Buffer = null;
        var download_fba: ?gpu.Buffer.Allocator = null;
        if (gpu_instance) |gpu_inst| {
            upload_buffer = try gpu.Buffer.init(gpu_inst, config.upload_buffer_size_bytes, .upload);
            if (upload_buffer) |*ub| {
                upload_fba = try ub.fixedBufferAllocator(allocator);
                errdefer ub.deinit();
            }
            download_buffer = try gpu.Buffer.init(gpu_inst, config.download_buffer_size_bytes, .download);
            if (download_buffer) |*db| {
                download_fba = try db.fixedBufferAllocator(allocator);
                errdefer db.deinit();
            }
        }

        var module_pool: ModulePool = .init(allocator);
        errdefer module_pool.deinit();

        var module_name_map: std.StringHashMap(ModuleHandle) = .init(allocator);
        errdefer module_name_map.deinit();

        var module_execution_order = std.ArrayList(ModuleHandle).initCapacity(allocator, 2) catch unreachable;
        errdefer module_execution_order.deinit(allocator);

        var repo: Modules.Repository = try .init(allocator);
        errdefer repo.deinit();

        var node_pool: NodePool = .init(allocator);
        errdefer node_pool.deinit();

        var node_execution_order = std.ArrayList(NodeHandle).initCapacity(allocator, 2) catch unreachable;
        errdefer node_execution_order.deinit(allocator);

        // var connector_pool: ConnectorPool = .init(allocator);
        // errdefer connector_pool.deinit();

        var param_buffer_pool: ParamBufferPool = .init(allocator);
        errdefer param_buffer_pool.deinit();

        const history: PipelineHistory = .init(allocator, io);

        return Pipeline{
            .allocator = allocator,
            .io = io,
            .gpu = gpu_instance,

            .history = history,
            .run_arena = std.heap.ArenaAllocator.init(allocator),

            .upload_buffer = upload_buffer,
            .upload_fba = upload_fba,

            .download_buffer = download_buffer,
            .download_fba = download_fba,

            .module_pool = module_pool,
            .module_name_map = module_name_map,
            .module_execution_order = module_execution_order,
            .repo = repo,

            .node_pool = node_pool,
            .node_execution_order = node_execution_order,

            // .connector_pool = connector_pool,

            .param_buffer_pool = param_buffer_pool,

            .perf = try .init(allocator, io),
        };
    }

    pub fn deinit(self: *Pipeline) void {
        slog.debug("De-initializing Pipeline", .{});
        self.runModulesDeinit();
        self.runModulesDeinitParams();
        // the pool deinit will take care of deallocating the textures
        self.module_execution_order.deinit(self.allocator);
        self.repo.deinit();
        var module_name_map_it = self.module_name_map.iterator();
        while (module_name_map_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.module_name_map.deinit();
        self.module_pool.deinit();
        self.node_execution_order.deinit(self.allocator);
        self.node_pool.deinit();
        // self.connector_pool.deinit();
        self.param_buffer_pool.deinit();
        self.history.deinit();
        self.perf.deinit();
        self.run_arena.deinit();

        if (self.upload_fba) |*upload_fba| {
            upload_fba.deinit(self.allocator);
        }
        if (self.download_fba) |*download_fba| {
            download_fba.deinit(self.allocator);
        }
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

    /// Public edit op: resolve `name` from the registered repos, add the
    /// module (instance `id`), and record a `module:` delta in history.
    pub fn addModule(self: *Pipeline, id: []const u8, name: []const u8) !ModuleHandle {
        const module_handle = try self._addModule(id, name);
        try self.history.recordModuleDelta(self.allocator, name, id);
        return module_handle;
    }

    /// Internal primitive: add a module, no history recorded.
    /// Prefer `addModule` (which records a delta) from user-facing editing code.
    pub fn addModuleNoRecord(self: *Pipeline, id: []const u8, name: []const u8) !ModuleHandle {
        return self._addModule(id, name);
    }

    fn _addModule(self: *Pipeline, id: []const u8, name: []const u8) !ModuleHandle {
        slog.debug("Adding module to pipeline: '{s}'", .{name});
        const module_desc = self.repo.get(name) orelse return error.ModuleNotFound;
        const module = try Module.init(id, module_desc);
        // try self.initOutputConnectorHandles(&module);
        self.rerouted = true;
        const module_handle = try self.module_pool.add(module);

        const fullname = try std.mem.concat(self.allocator, u8, &.{ module.desc.name, ":", id });

        try self.module_name_map.put(fullname, module_handle);
        try self.initParams(module_handle);
        return module_handle;
    }

    pub fn addNode(self: *Pipeline, mod_handle: ModuleHandle, node_desc: api.NodeDesc) !NodeHandle {
        slog.debug("Adding node to pipeline: '{s}'", .{node_desc.name});
        const node = try Node.init(self, mod_handle, node_desc);
        // try self.initOutputConnectorHandles(&node);
        self.rerouted = true;
        return try self.node_pool.add(node);
    }

    pub fn connectModulesByName(
        self: *Pipeline,
        src_mod_name: []const u8,
        src_mod_id: []const u8,
        src_mod_socket_name: []const u8,
        dst_mod_name: []const u8,
        dst_mod_id: []const u8,
        dst_mod_socket_name: []const u8,
    ) !void {
        const src_mod_fullname = try std.mem.concat(self.allocator, u8, &.{ src_mod_name, ":", src_mod_id });
        defer self.allocator.free(src_mod_fullname);

        const src_mod = self.module_name_map.get(src_mod_fullname) orelse return error.ModuleNotFound;

        const dst_mod_fullname = try std.mem.concat(self.allocator, u8, &.{ dst_mod_name, ":", dst_mod_id });
        defer self.allocator.free(dst_mod_fullname);

        const dst_mod = self.module_name_map.get(dst_mod_fullname) orelse return error.ModuleNotFound;

        try self._connectModules(src_mod, src_mod_socket_name, dst_mod, dst_mod_socket_name);

        try self.history.recordConnectDelta(self.allocator, src_mod, src_mod_socket_name, dst_mod, dst_mod_socket_name);
        return;
    }

    pub fn connectModulesByNameNoRecord(
        self: *Pipeline,
        src_mod_name: []const u8,
        src_mod_id: []const u8,
        src_mod_socket_name: []const u8,
        dst_mod_name: []const u8,
        dst_mod_id: []const u8,
        dst_mod_socket_name: []const u8,
    ) !void {
        const src_mod_fullname = try std.mem.concat(self.allocator, u8, &.{ src_mod_name, ":", src_mod_id });
        defer self.allocator.free(src_mod_fullname);

        const src_mod = self.module_name_map.get(src_mod_fullname) orelse return error.ModuleNotFound;

        const dst_mod_fullname = try std.mem.concat(self.allocator, u8, &.{ dst_mod_name, ":", dst_mod_id });
        defer self.allocator.free(dst_mod_fullname);

        const dst_mod = self.module_name_map.get(dst_mod_fullname) orelse return error.ModuleNotFound;

        return try self._connectModules(src_mod, src_mod_socket_name, dst_mod, dst_mod_socket_name);
    }

    pub fn connectModules(
        self: *Pipeline,
        src_mod: ModuleHandle,
        src_mod_socket_name: []const u8,
        dst_mod: ModuleHandle,
        dst_mod_socket_name: []const u8,
    ) !void {
        try self._connectModules(src_mod, src_mod_socket_name, dst_mod, dst_mod_socket_name);
        try self.history.recordConnectDelta(self.allocator, src_mod, src_mod_socket_name, dst_mod, dst_mod_socket_name);
        return;
    }

    fn _connectModules(
        self: *Pipeline,
        src_mod: ModuleHandle,
        src_mod_socket_name: []const u8,
        dst_mod: ModuleHandle,
        dst_mod_socket_name: []const u8,
    ) !void {
        // slog.debug("Connecting module {any} socket {s} to module {any} socket {s}", .{ src_mod, src_mod_socket_name, dst_mod, dst_mod_socket_name });
        var src_mod_ptr = try self.module_pool.getPtr(src_mod);
        var dst_mod_ptr = try self.module_pool.getPtr(dst_mod);

        slog.debug("Connecting module '{s} > {s}' to module '{s} > {s}'", .{ src_mod_ptr.desc.name, src_mod_socket_name, dst_mod_ptr.desc.name, dst_mod_socket_name });
        const dst_socket_idx = try dst_mod_ptr.getSocketIndex(dst_mod_socket_name);
        const src_socket_idx = try src_mod_ptr.getSocketIndex(src_mod_socket_name);

        var dst_mod_socket = &(dst_mod_ptr.sockets[dst_socket_idx] orelse {
            slog.err("Destination module '{s} > {s}' is null", .{ dst_mod_ptr.desc.name, dst_mod_socket_name });
            return error.ModuleSocketNotFound;
        });
        const src_mod_socket = &(src_mod_ptr.sockets[src_socket_idx] orelse {
            slog.err("Source module '{s} > {s}' is null", .{ src_mod_ptr.desc.name, src_mod_socket_name });
            return error.ModuleSocketNotFound;
        });

        if (!Socket.areCompatible(src_mod_socket, dst_mod_socket)) {
            slog.err("Incompatible module socket connection from '{s} > {s}' to '{s} > {s}'", .{ src_mod_ptr.desc.name, src_mod_socket_name, dst_mod_ptr.desc.name, dst_mod_socket_name });
            return error.ModuleSocketConnectionIncompatible;
        }
        dst_mod_socket.connected_to_module = .{
            .item = src_mod,
            .socket_idx = src_socket_idx,
        };
        self.rerouted = true;
    }

    pub fn connectNodesByName(
        self: *Pipeline,
        src_node: NodeHandle,
        src_node_socket_name: []const u8,
        dst_node: NodeHandle,
        dst_node_socket_name: []const u8,
    ) !void {
        // slog.debug("Connecting node {any} socket {s} to node {any} socket {s}", .{ src_node, src_node_socket_name, dst_node, dst_node_socket_name });
        var src_node_ptr = try self.node_pool.getPtr(src_node);
        var dst_node_ptr = try self.node_pool.getPtr(dst_node);

        slog.debug("Connecting node '{s} > {s}' to node '{s} > {s}'", .{ src_node_ptr.name, src_node_socket_name, dst_node_ptr.name, dst_node_socket_name });
        const dst_socket_idx = try dst_node_ptr.getSocketIndex(dst_node_socket_name);
        const src_socket_idx = try src_node_ptr.getSocketIndex(src_node_socket_name);

        var dst_node_socket = &(dst_node_ptr.sockets[dst_socket_idx] orelse {
            slog.err("Destination node '{s} > {s}' is null", .{ dst_node_ptr.name, dst_node_socket_name });
            return error.NodeSocketNotFound;
        });
        const src_node_socket = &(src_node_ptr.sockets[src_socket_idx] orelse {
            slog.err("Source node '{s} > {s}' is null", .{ src_node_ptr.name, src_node_socket_name });
            return error.NodeSocketNotFound;
        });

        if (!Socket.areCompatible(src_node_socket, dst_node_socket)) {
            slog.err("Incompatible node socket connection from '{s} > {s}' to '{s} > {s}'", .{ src_node_ptr.name, src_node_socket_name, dst_node_ptr.name, dst_node_socket_name });
            return error.NodeSocketConnectionIncompatible;
        }

        dst_node_socket.connected_to_node = .{
            .item = src_node,
            .socket_idx = src_socket_idx,
        };
        self.rerouted = true;
    }

    pub fn inheritSocket(
        self: *Pipeline,
        mod_handle: ModuleHandle,
        mod_socket_name: []const u8,
        node_handle: NodeHandle,
        node_socket_name: []const u8,
    ) !void {
        // slog.debug("Copying module {any} > {s} to node {any} > {s}", .{ mod_handle, mod_socket_name, node_handle, node_socket_name });

        var mod = try self.module_pool.getPtr(mod_handle);
        var node = try self.node_pool.getPtr(node_handle);
        slog.debug("Copying connector from module '{s} > {s}' to node '{s} > {s}'", .{ mod.desc.name, mod_socket_name, node.name, node_socket_name });

        const mod_socket_idx = try mod.getSocketIndex(mod_socket_name);
        const node_socket_idx = try node.getSocketIndex(node_socket_name);

        const node_socket = &(node.sockets[node_socket_idx] orelse {
            slog.err("Destination node '{s} > {s}' is null", .{ node.name, node_socket_name });
            return error.NodeSocketNotFound;
        });
        const mod_socket = &(mod.sockets[mod_socket_idx] orelse {
            slog.err("Source module '{s} > {s}' is null", .{ mod.desc.name, mod_socket_name });
            return error.ModuleSocketNotFound;
        });
        if (!Socket.areSimilar(mod_socket, node_socket)) {
            slog.err("Incompatible connector copy from module '{s} > {s}' to node '{s} > {s}'", .{ mod.desc.name, mod_socket_name, node.name, node_socket_name });
            return error.ModuleNodeSocketConnectionIncompatible;
        }

        // perform copy
        node_socket.* = mod_socket.*;

        // for input sockets on nodes
        if (node_socket.type.direction() == .input) {
            node_socket.inherited_from_module = .{
                .item = mod_handle,
                .socket_idx = mod_socket_idx,
            };
        }

        // for output sockets on modules
        if (mod_socket.type.direction() == .output) {
            mod_socket.inherited_by_node = .{
                .item = node_handle,
                .socket_idx = node_socket_idx,
            };
        }
        self.rerouted = true;
    }

    pub fn getModuleParamPtr(self: *Pipeline, mod_handle: ModuleHandle, param_name: []const u8) ?*api.Param {
        const mod = self.module_pool.getPtr(mod_handle) orelse return null;
        return mod.getParamPtr(param_name);
    }

    pub fn setModuleParam(self: *Pipeline, mod_handle: ModuleHandle, param_name: []const u8, T: type, value: T) !void {
        const mod = try self.module_pool.getPtr(mod_handle);
        const param = try mod.getParamPtr(param_name);
        try param.set(value);
        self.dirty = true;
        mod.dirty = true;
        try self.history.recordParamDelta(self.allocator, mod_handle, param_name);
    }

    pub fn disconnectModule(self: *Pipeline, dst_mod: ModuleHandle, dst_mod_socket_name: []const u8) !void {
        try self._disconnectModule(dst_mod, dst_mod_socket_name);
        try self.history.recordDisconnectDelta(self.allocator, dst_mod, dst_mod_socket_name);
        return;
    }

    /// Disconnect a module input socket by name+instance (used by replay).
    pub fn disconnectModuleByName(self: *Pipeline, dst_mod_name: []const u8, dst_mod_id: []const u8, dst_mod_socket: []const u8) !void {
        const fullname = try std.mem.concat(self.allocator, u8, &.{ dst_mod_name, ":", dst_mod_id });
        defer self.allocator.free(fullname);
        const dst_mod = self.module_name_map.get(fullname) orelse return error.ModuleNotFound;
        try self._disconnectModule(dst_mod, dst_mod_socket);
        try self.history.recordDisconnectDelta(self.allocator, dst_mod, dst_mod_socket);
    }

    pub fn disconnectModuleByNameNoRecord(self: *Pipeline, dst_mod_name: []const u8, dst_mod_id: []const u8, dst_mod_socket: []const u8) !void {
        const fullname = try std.mem.concat(self.allocator, u8, &.{ dst_mod_name, ":", dst_mod_id });
        defer self.allocator.free(fullname);
        const dst_mod = self.module_name_map.get(fullname) orelse return error.ModuleNotFound;
        try self._disconnectModule(dst_mod, dst_mod_socket);
    }

    fn _disconnectModule(
        self: *Pipeline,
        dst_mod: ModuleHandle,
        dst_mod_socket_name: []const u8,
    ) !void {
        const dst = try self.module_pool.getPtr(dst_mod);
        const idx = try dst.getSocketIndex(dst_mod_socket_name);
        if (dst.sockets[idx]) |*sock| {
            sock.connected_to_module = null;
        } else {
            return error.ModuleSocketNotFound;
        }
        self.rerouted = true;
    }

    /// Remove a module and record a `removemodule:` delta.
    pub fn removeModule(self: *Pipeline, module_handle: ModuleHandle) !void {
        const mod = try self.module_pool.getPtr(module_handle);
        try self._removeModule(module_handle);
        try self.history.recordRemoveDelta(self.allocator, mod.desc.name, mod.id);
    }

    /// Remove a module by name+instance (used by replay), freeing its map key,
    /// params, deinit hook and pool slot.
    pub fn removeModuleByName(self: *Pipeline, dst_mod_name: []const u8, dst_mod_id: []const u8) !void {
        const fullname = try std.mem.concat(self.allocator, u8, &.{ dst_mod_name, ":", dst_mod_id });
        defer self.allocator.free(fullname);
        const kv = self.module_name_map.fetchRemove(fullname) orelse return error.ModuleNotFound;
        self.allocator.free(kv.key);
        const mod_handle = kv.value;
        try self._removeModule(mod_handle);
        try self.history.recordRemoveDelta(self.allocator, dst_mod_name, dst_mod_id);
    }

    fn _removeModule(
        self: *Pipeline,
        mod_handle: ModuleHandle,
    ) !void {
        const mod = self.module_pool.getPtr(mod_handle) catch return error.ModuleNotFound;
        for (&mod.params) |*maybe_param_ptr| {
            if (maybe_param_ptr.*) |*param| param.deinit(self.allocator);
        }
        if (mod.desc.deinit) |deinitFn| deinitFn(self.allocator, self, mod_handle);
        mod.deinit(); // although module_pool.remove() will call deinit if it exists...
        self.module_pool.remove(mod_handle);
    }

    pub fn undo(self: *Pipeline) !void {
        try self.history.undo();
        self.rerouted = true;
        self.dirty = true;
    }

    pub fn redo(self: *Pipeline) !void {
        try self.history.redo();
        self.rerouted = true;
        self.dirty = true;
    }

    /// Run the pipeline. Uses the pipeline-owned `run_arena` for temporary
    /// allocations; it is reset at the start of each run, so callers don't
    /// need to manage a scratch arena.
    pub fn run(self: *Pipeline) !void {

        // reset the scratch arena: all per-run temporaries (graphs, ordering,
        // staging lists) are freed and reused
        _ = self.run_arena.reset(.retain_capacity);
        const arena = self.run_arena.allocator();

        slog.info("Running pipeline", .{});

        try self.perf.startRun();

        if (self.rerouted) {
            // First run modules so we know which nodes to create, what rois, buffers, and textures to allocate
            try self.runModulesBuildExecutionOrder(arena);
            try self.perf.timerLap("runModulesBuildExecutionOrder");

            for (self.module_execution_order.items) |module_handle| {
                const module = try self.module_pool.getPtr(module_handle);
                try self.runModulePreCheck(module);
                try self.runModuleInit(module_handle, module);
                try self.runModuleCreateParamBufferHandles(module);
                try self.runModuleModifyOut(module_handle, module);
                try self.runModuleInitParamBuffers(module);
                try self.runModuleAllocateUploadBufferForParams(module);
            }
            try self.perf.timerLap("runModules");

            try self.runModulesReCreateNodes(arena);
            try self.perf.timerLap("runModulesReCreateNodes");

            // Then run nodes
            try self.runNodesBuildExecutionOrder(arena);
            try self.perf.timerLap("runNodesBuildExecutionOrder");
            try self.runNodesCompileShaders();
            try self.perf.timerLap("runNodesCompileShaders");
            try self.runNodesInitConnectorTextures(.{});
            try self.perf.timerLap("runNodesInitConnectorTextures");
            try self.runNodesCreateBindings(.{ .only_dirty = true });
            try self.perf.timerLap("runNodesCreateBindings");
            try self.runNodesAllocateStagingBuffersForTextures();
            try self.perf.timerLap("runNodesAllocateStagingBuffersForTextures");

            // try self.freeUnusedConnectors(arena);
            try self.perf.timerLap("freeUnusedConnectors");

            self.printPipeToStdout();
            self.rerouted = false;
            self.dirty = true;
            self.runModulesMarkDirty(); // full rebuild: everything needs to run
        }

        if (self.dirty) {
            // re-run modifyOut so modules can update output rois/format from the
            // changed params (e.g. swap-roi); then detect stale connector textures
            try self.runModulesModifyOut();
            try self.perf.timerLap("runModulesModifyOut2");
            try self.runNodeSyncSockets();
            try self.perf.timerLap("runNodeSyncSockets");
            try self.runNodesInitConnectorTextures(.{ .refresh = true });
            try self.perf.timerLap("runNodesInitConnectorTextures(refresh)");

            try self.runModulesUploadParams(arena);
            try self.perf.timerLap("runModulesUploadParams");
            try self.runNodesUploadSource();
            try self.perf.timerLap("runNodesUploadSource");
            try self.runNodesCreateBindings(.{ .only_dirty = true });
            try self.perf.timerLap("runNodesCreateBindings2");
            try self.runNodes(.{ .only_dirty = true });
            try self.perf.timerLap("runNodes");
            try self.runNodesDownloadSink();
            try self.perf.timerLap("runNodesDownloadSink");

            self.dirty = false;
            self.runModulesClearDirtyFlag();
        }

        {
            self.perf.recordUploadBufferUsage(self.upload_fba);
            self.perf.recordDownloadBufferUsage(self.download_fba);
            self.perf.countModules(&self.module_pool);
            self.perf.countNodes(&self.node_pool);
            // self.perf.countConnectors(&self.connector_pool);
            self.perf.printReport();
        }
    }

    pub fn printPipeToStdout(self: *Pipeline) void {
        // print.printModules(self);
        // print.printNodes(self);
        print.printNodesGraph(self) catch unreachable;
        // print.printNodeExecutionOrder(self);
    }

    pub fn getDisplaySinkTexture(self: *Pipeline) !gpu.Texture {
        const last_node_handle = self.node_execution_order.items[self.node_execution_order.items.len - 1];
        const last_node = try self.node_pool.getPtr(last_node_handle);
        slog.debug("Getting display sink texture for last node '{s}'", .{last_node.name});
        const sock = last_node.sockets[0] orelse return error.NodeOutputSocketMissingConnectorHandle;
        const tex = self.getNodeSocketTexture(sock) orelse return error.NodeOutputSocketMissingConnectorHandle;
        return tex;
    }

    // ================================================
    // Private Pipeline functions
    // ================================================

    /// Tear down every module (freeing params, name-map keys and module deinit
    /// hooks) and node (freeing shaders/bindings). Connectors are left alone:
    /// they are a growth pool shared by modules and get recycled lazily.
    pub fn clear(self: *Pipeline) void {
        var mod_handles = self.removeAllModules();
        defer mod_handles.deinit(self.allocator);

        var node_handles = std.ArrayList(NodeHandle).empty;
        defer node_handles.deinit(self.allocator);
        var it = self.node_pool.liveHandles();
        while (it.next()) |h| node_handles.append(self.allocator, h) catch unreachable;
        for (node_handles.items) |h| self.node_pool.remove(h);

        self.rerouted = true;
    }

    /// Free every module name-map key, clear the map, remove every module
    /// (params + deinit hook + pool slot), and return the handles (already
    /// removed) for the caller's convenience.
    fn removeAllModules(self: *Pipeline) std.ArrayList(ModuleHandle) {
        var handles = std.ArrayList(ModuleHandle).empty;
        var map_it = self.module_name_map.iterator();
        while (map_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.module_name_map.clearRetainingCapacity();

        var mod_it = self.module_pool.liveHandles();
        while (mod_it.next()) |h| {
            const mod = self.module_pool.getPtr(h) catch continue;
            for (&mod.params) |*maybe_param_ptr| {
                if (maybe_param_ptr.*) |*param| param.deinit(self.allocator);
            }
            if (mod.desc.deinit) |deinitFn| deinitFn(self.allocator, self, h);
            self.module_pool.remove(h);
            handles.append(self.allocator, h) catch unreachable;
        }
        return handles;
    }

    fn initParams(self: *Pipeline, module_handle: ModuleHandle) !void {
        const module = try self.module_pool.getPtr(module_handle);
        if (module.desc.initParams) |initParamsFn| {
            try initParamsFn(self, module_handle);
        }
    }

    /// pub for util printing purposes
    pub fn getNodeSocketTexture(self: *Pipeline, socket: Socket) ?gpu.Texture {
        if (socket.texture) |texture| {
            return texture;
        } else if (self.getConnectedNode(socket)) |connected_node_connection| {
            const connected_node = self.node_pool.getPtr(connected_node_connection.item) catch return null;
            const connected_node_socket = connected_node.sockets[connected_node_connection.socket_idx] orelse return null;
            const connected_texture = connected_node_socket.texture orelse return null;
            return connected_texture;
        }
        return null;
    }

    /// pub for debugging purposes
    pub fn getConnectedNode(pipe: *Pipeline, socket: Socket) ?Socket.SocketConnection(NodeHandle) {
        if (socket.connected_to_node) |src_node_handle_connection| {
            return src_node_handle_connection;
        } else if (socket.inherited_from_module) |assoc_mod_handle_connection| {
            // if the node is not directly connected to another node,
            // check if it is linked to a module then check what that
            // module is connected to and then traverse to the node that
            // is linked to that socket and connect to that node
            const assoc_mod = pipe.module_pool.getPtr(assoc_mod_handle_connection.item) catch unreachable;
            const assoc_mod_socket = assoc_mod.sockets[assoc_mod_handle_connection.socket_idx] orelse unreachable;
            if (assoc_mod_socket.connected_to_module) |connected_to_mod_handle_connection| {
                const connected_to_mod = pipe.module_pool.getPtr(connected_to_mod_handle_connection.item) catch unreachable;
                const connected_to_mod_socket = connected_to_mod.sockets[connected_to_mod_handle_connection.socket_idx] orelse unreachable;
                if (connected_to_mod_socket.inherited_by_node) |src_node_handle_connection| {
                    return src_node_handle_connection;
                }
            }
        }
        return null;
    }

    fn runModulePreCheck(self: *Pipeline, module: *Module) !void {
        _ = self;
        if (module.desc.type == .source) {
            const input_socket = module.getSocketPtr("input") catch null;
            if (input_socket != null) {
                slog.err("Source module '{s}' has an input socket defined", .{module.desc.name});
                return error.ModuleSourceHasInputSocket;
            }
        }
        if (module.desc.type == .compute) {
            const input_socket = module.getSocketPtr("input") catch null;
            if (input_socket == null) {
                slog.err("Compute module '{s}' has no input socket defined", .{module.desc.name});
                return error.ModuleComputeMissingInputSocket;
            }
            const output_socket = module.getSocketPtr("output") catch null;
            if (output_socket == null) {
                slog.err("Compute module '{s}' has no output socket defined", .{module.desc.name});
                return error.ModuleComputeMissingOutputSocket;
            }
        }
    }

    // build execution order of modules based on DAG
    fn runModulesBuildExecutionOrder(self: *Pipeline, arena: std.mem.Allocator) !void {
        // clear previous execution order
        self.module_execution_order.clearAndFree(self.allocator);

        // OPTION #1
        const ModuleGraph = DirectedGraph(ModuleHandle, ConnectorHandle(ModuleHandle), std.hash_map.AutoContext(ModuleHandle));
        var module_graph = ModuleGraph.init(arena);
        defer module_graph.deinit();
        try buildGraph(Module, &self.module_pool, &module_graph);
        var iter = try module_graph.topSortIterator();
        defer iter.deinit();
        while (try iter.next()) |value| {
            try self.module_execution_order.append(self.allocator, module_graph.lookup(value).?);
        }

        // OPTION #2
        // var module_dag_iter = try PooledDagDfsIterator(Module).iterator(arena, &self.module_pool);
        // defer module_dag_iter.deinit();
        // while (module_dag_iter.next()) |maybe_node_handle| {
        //     const node_handle = maybe_node_handle orelse break;
        //     try self.module_execution_order.append(self.allocator, node_handle);
        // } else |err| {
        //     slog.debug("Error during DAG traversal: {any}\n", .{err});
        // }
        // slog.debug("Topological sorted order of modules: {any}", .{self.module_execution_order.items});
    }

    fn runModuleInit(self: *Pipeline, module_handle: ModuleHandle, module: *Module) !void {
        if (module.desc.init) |initFn| {
            try initFn(self.allocator, self.io, self, module_handle);
        }
    }

    /// configure connectors only for module output connectors
    fn runModuleCreateParamBufferHandles(self: *Pipeline, module: *Module) !void {
        module.img_param_handle = try self.param_buffer_pool.add(null);
        if (module.params_len() != 0) {
            module.param_handle = try self.param_buffer_pool.add(null);
        }
    }

    /// set roi out for each module based on connected modules
    /// and call modifyOut if defined
    /// we also propagate img_param and color_profile down the pipeline here
    fn runModulesModifyOut(self: *Pipeline) !void {
        for (self.module_execution_order.items) |module_handle| {
            const module = try self.module_pool.getPtr(module_handle);
            try self.runModuleModifyOut(module_handle, module);
        }
    }

    /// set roi out for each module based on connected modules
    /// and call modifyOut if defined
    /// we also propagate img_param and color_profile down the pipeline here
    fn runModuleModifyOut(self: *Pipeline, module_handle: ModuleHandle, module: *Module) !void {
        // set roi/color_profile in based on connected module out
        for (module.sockets) |socket| {
            if (socket) |sock| {
                if (sock.type.direction() == .input) {
                    if (sock.connected_to_module) |connection| {
                        const connected_to_module = try self.module_pool.getPtr(connection.item);
                        var socket_ptr = try module.getSocketPtr(sock.name);
                        // slog.debug("Setting input ROI for module '{s} > {s}' from previous connected module '{s}'", .{ module.desc.name, sock.name, connected_to_module.desc.name });
                        const connected_to_socket = connected_to_module.sockets[connection.socket_idx] orelse unreachable;
                        socket_ptr.roi = connected_to_socket.roi;
                        // carry the actual color profile of what is flowing in
                        socket_ptr.color_profile = connected_to_socket.color_profile;

                        // propagate img_param from connected module to this module
                        module.img_param = connected_to_module.img_param;
                    }
                }
            }
        }

        // modify out
        if (module.desc.modifyOut) |modifyOutFn| {
            try modifyOutFn(self, module_handle);
        } else {
            // auto propagate roi from input to output
            if (module.desc.type != .source and module.desc.type != .sink) {
                const input_socket = try module.getSocketPtr("input");
                const output_socket = try module.getSocketPtr("output");
                output_socket.roi = input_socket.roi;
            }
        }
    }

    fn runModuleInitParamBuffers(self: *Pipeline, module: *Module) !void {
        const gpu_inst = self.gpu orelse return error.PipelineNoGPUInstance;
        if (module.desc.type == .compute) {
            if (module.enabled == false) return;
            params: { // PARAM BUFFER INIT
                var size_bytes: usize = 0;
                var tu: [api.MAX_PARAMS_PER_MODULE]Param = undefined;
                var tu_len: usize = 0;
                for (module.params, 0..) |param, idx| {
                    if (param) |p| {
                        tu[idx] = p;
                        tu_len += 1;
                    }
                }
                if (tu_len == 0) break :params;
                size_bytes = try Param.layoutTaggedUnion(null, tu[0..tu_len]);
                const param_buffer = try gpu.Buffer.init(gpu_inst, size_bytes, .storage);
                // defer texture.deinit();
                // store texture in connector pool
                if (module.param_handle) |param_handle| {
                    const mod_param_buffer = try self.param_buffer_pool.getPtr(param_handle);
                    mod_param_buffer.* = param_buffer;
                    module.param_size = size_bytes;
                }
            }
            { // IMG PARAM BUFFER INIT
                var size_bytes: usize = 0;
                if (module.img_param) |img_param| {
                    size_bytes = try gpu.data.layoutStruct(null, img_param);
                }
                const img_param_buffer = try gpu.Buffer.init(gpu_inst, size_bytes, .uniform);
                if (module.img_param_handle) |img_param_handle| {
                    const mod_img_param_buffer = try self.param_buffer_pool.getPtr(img_param_handle);
                    mod_img_param_buffer.* = img_param_buffer;
                    module.img_param_size = size_bytes;
                }
            }
        }
    }

    fn runModuleAllocateUploadBufferForParams(self: *Pipeline, module: *Module) !void {
        if (self.upload_fba) |*upload_fba| {
            var upload_allocator = upload_fba.allocator();

            if (module.desc.type == .compute) {
                if (module.enabled == false) return;
                blk: {
                    const size_bytes = module.param_size orelse break :blk;
                    slog.debug("Allocating upload buffer for params for size {d} bytes", .{size_bytes});
                    const mapped_param_slice = try upload_allocator.alignedAlloc(u8, gpu.COPY_BUFFER_ALIGNMENT, size_bytes);
                    module.param_offset = @intFromPtr(mapped_param_slice.ptr) - @intFromPtr(upload_fba.ptr);
                    module.param_mapped_slice_ptr = @ptrCast(@alignCast(mapped_param_slice.ptr));
                }
                blk: {
                    const size_bytes = module.img_param_size orelse break :blk;
                    slog.debug("Allocating upload buffer for img params for size {d} bytes", .{size_bytes});
                    const mapped_img_param_slice = try upload_allocator.alignedAlloc(u8, gpu.COPY_BUFFER_ALIGNMENT, size_bytes);
                    module.img_param_offset = @intFromPtr(mapped_img_param_slice.ptr) - @intFromPtr(upload_fba.ptr);
                    module.img_param_mapped_slice_ptr = @ptrCast(@alignCast(mapped_img_param_slice.ptr));
                }
            }
        }
    }

    /// remove all existing nodes and
    /// create nodes for each module
    fn runModulesReCreateNodes(self: *Pipeline, arena: std.mem.Allocator) !void {
        var old_node_handles = try std.ArrayList(NodeHandle).initCapacity(arena, self.node_pool.len());
        defer old_node_handles.deinit(arena);

        var node_pool_handles = self.node_pool.liveHandles();
        while (node_pool_handles.next()) |node_handle| {
            try old_node_handles.append(arena, node_handle);
        }

        for (old_node_handles.items) |node_handle| {
            // remove node
            // we leave connectors alone for now since they are shared with modules and may be reused
            slog.debug("Removing node '{any}' from pipeline", .{node_handle});
            self.node_pool.remove(node_handle);
        }

        for (self.module_execution_order.items) |module_handle| {
            const module = try self.module_pool.getPtr(module_handle);
            if (module.enabled == false) continue;
            if (module.desc.createNodes) |createNodesFn| {
                try createNodesFn(self, module_handle);
            }
        }
    }

    /// Builds a DAG graph for the node by connecting nodes based on connected_to_* and associated_with_* fields,
    /// then performs a topological sort to determine execution order
    fn runNodesBuildExecutionOrder(self: *Pipeline, arena: std.mem.Allocator) !void {
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
            const dst_node = try self.node_pool.getPtr(dst_node_handle);
            for (&dst_node.sockets) |*socket| {
                if (socket.*) |*sock| {
                    if (self.getConnectedNode(sock.*)) |src_node_handle_connection| {
                        sock.connected_to_node = src_node_handle_connection; // flatten meta connection
                    }
                }
            }
        }

        // clear previous execution order
        self.node_execution_order.clearAndFree(self.allocator);

        // OPTION #1
        const NodeGraph = DirectedGraph(NodeHandle, ConnectorHandle(NodeHandle), std.hash_map.AutoContext(NodeHandle));
        var node_graph = NodeGraph.init(arena);
        defer node_graph.deinit();
        try buildGraph(Node, &self.node_pool, &node_graph);
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

        // slog.debug("Topological sorted order of nodes: {any}", .{self.node_execution_order.items});
    }

    fn runNodesCompileShaders(self: *Pipeline) !void {
        for (self.node_execution_order.items) |node_handle| {
            var node = try self.node_pool.getPtr(node_handle);
            if (node.shader) |_| {
                slog.debug("Node '{s}' already has a compiled shader, skipping compilation", .{node.name});
                continue;
            }
            if (node.shader_source) |shader| {
                node.shader = try api.compileShader(self, shader);
            }
        }
    }

    const InitConnectorTexturesOptions = struct {
        /// refresh mode: only (re)create textures whose roi/format no longer
        /// match the module socket (authoritative after modifyOut), free stale
        /// textures, sync node socket roi/format, and mark the node dirty.
        refresh: bool = false,
    };

    /// Allocates output textures and creates compute shaders for each node
    /// also creates bindings for each shader
    ///
    /// similar to vkdt dt_graph_run_nodes_allocate()
    fn runNodesInitConnectorTextures(self: *Pipeline, options: InitConnectorTexturesOptions) !void {
        const gpu_inst = self.gpu orelse return error.PipelineNoGPUInstance;
        for (self.node_execution_order.items) |node_handle| {
            const node = try self.node_pool.getPtr(node_handle);
            const mod = try self.module_pool.getPtr(node.mod);
            for (&node.sockets) |*socket| {
                if (socket.*) |*sock| {
                    if (sock.type.direction() != .output) continue;

                    // resolve the authoritative roi/format: in refresh mode the
                    // module socket (updated by modifyOut) wins; otherwise the
                    // node socket (as created by createNodes)
                    var roi: ?api.ROI = null;
                    var fmt: gpu.TextureFormat = sock.format;
                    if (options.refresh) {
                        const mod_sock = mod.getSocketPtr(sock.name) catch continue;
                        roi = mod_sock.roi;
                        fmt = mod_sock.format;
                    } else {
                        roi = sock.roi;
                    }
                    const expected_roi = roi orelse continue;

                    const need_alloc = blk: {
                        const tex = sock.texture orelse break :blk true;
                        if (options.refresh) {
                            if (!std.meta.eql(tex.roi, expected_roi)) break :blk true;
                            if (tex.format != fmt) break :blk true;
                        }
                        break :blk false;
                    };
                    if (!need_alloc) continue;

                    var buf: [256]u8 = undefined;
                    const str = try std.fmt.bufPrint(&buf, "node: {s} > {s}", .{ node.name, sock.name });
                    if (options.refresh) {
                        slog.debug("Refreshing output texture for node '{s} > {s}' (roi/format changed)", .{ node.name, sock.name });
                    } else {
                        slog.debug("Allocating output texture for node '{s} > {s}'", .{ node.name, sock.name });
                    }
                    // free the old texture before replacing (refresh only; full
                    // init starts with a null texture)
                    if (sock.texture) |*old| old.deinit();
                    const texture = try gpu.Texture.init(gpu_inst, str, fmt, expected_roi);
                    sock.texture = texture;
                    if (options.refresh) {
                        // keep the node socket in sync so run_size/bindings use the new roi
                        var sock_ptr = node.getSocketPtr(sock.name) catch continue;
                        sock_ptr.roi = expected_roi;
                        self.markNodeDirty(node);
                    }
                    self.perf.recordConnectorTextureAllocation();
                }
            }
        }
    }

    /// Sync each node's socket roi/format from its module's socket (the
    /// authoritative state after runModulesModifyOut). On reroute this happens
    /// naturally via createNodes; on dirty runs nodes keep their old sockets.
    /// O(total nodes * sockets) — cheap, but runs every dirty frame.
    fn runNodeSyncSockets(self: *Pipeline) !void {
        var node_it = self.node_pool.liveHandles();
        while (node_it.next()) |node_handle| {
            const node = try self.node_pool.getPtr(node_handle);
            const mod = try self.module_pool.getPtr(node.mod);
            for (&node.sockets) |*maybe_sock| {
                if (maybe_sock.*) |*sock| {
                    if (mod.getSocketPtr(sock.name)) |mod_sock| {
                        sock.roi = mod_sock.roi;
                        sock.format = mod_sock.format;
                        sock.color_profile = mod_sock.color_profile;
                    } else |_| {}
                }
            }
        }
    }

    /// Re-run only the dirty nodes (plus their DAG successors), in topo order.
    const RunNodesOptions = struct {
        /// only enqueue nodes marked dirty (and their DAG successors).
        /// default: run every node (full pass).
        only_dirty: bool = false,
    };

    fn runNodesCreateBindings(self: *Pipeline, options: RunNodesOptions) !void {
        const gpu_inst = self.gpu orelse return error.PipelineNoGPUInstance;
        for (self.node_execution_order.items) |node_handle| {
            const node = try self.node_pool.getPtr(node_handle);

            // only rebuild bindings for dirty nodes (texture/param changed); path
            // used by runNodes(.only_dirty=true) after connector refresh/param writes
            if (options.only_dirty and !self.nodeIsDirty(node)) continue;

            if (node.type == .compute) {
                // CREATE DESCRIPTIONS FOR BIND GROUP LAYOUTS AND BIND GROUPS
                var layout_group_0_binding: [gpu.MAX_BINDINGS]?gpu.BindGroupLayoutEntry = @splat(null);
                var bind_group_0_binds: [gpu.MAX_BINDINGS]?gpu.BindGroupEntry = @splat(null);
                const mod = try self.module_pool.getPtr(node.*.mod);

                // if we have params, they will be on group 0 binding 0
                // and the img_params will be on group 0 binding 1
                // else, if we dont have params, img_params will be on group 0 binding 0
                var group_0_bind_number: usize = 0;

                // params are on group 0
                if (mod.*.param_handle) |param_handle| {
                    const param_buffer = try self.param_buffer_pool.getPtr(param_handle);
                    const param_buf = param_buffer.* orelse return error.ModuleParamBufferNotAllocated;
                    layout_group_0_binding[group_0_bind_number] = .{ .buffer = .{ .binding_type = .storage } };
                    bind_group_0_binds[group_0_bind_number] = .{ .buffer = param_buf };
                    group_0_bind_number += 1;
                }

                // img params are also on group 0
                if (mod.*.img_param_handle) |img_param_handle| {
                    const img_param_buffer = try self.param_buffer_pool.getPtr(img_param_handle);
                    const img_param_buf = img_param_buffer.* orelse return error.ModuleImgParamBufferNotAllocated;
                    layout_group_0_binding[group_0_bind_number] = .{ .buffer = .{ .binding_type = .uniform } };
                    bind_group_0_binds[group_0_bind_number] = .{ .buffer = img_param_buf };
                    group_0_bind_number += 1;
                }

                // all sockets are on group 1
                var layout_group_1_binding: [gpu.MAX_BINDINGS]?gpu.BindGroupLayoutEntry = @splat(null);
                var bind_group_1_binds: [gpu.MAX_BINDINGS]?gpu.BindGroupEntry = @splat(null);
                for (node.sockets, 0..) |socket, binding_number| {
                    if (socket) |sock| {
                        // prepare shader pipe connections
                        layout_group_1_binding[binding_number] = gpu.BindGroupLayoutEntry{
                            .texture = .{
                                .access = sock.type.toComputePipelineBindGroupLayoutEntryAccess(),
                                .format = sock.format,
                            },
                        };
                        // slog.debug("Added bind group layout entry for binding {d}", .{binding_number});

                        // const texture = sock.texture orelse return error.NodeSocketMissingConnectorTexture;
                        const texture = self.getNodeSocketTexture(sock) orelse return error.NodeSocketMissingConnectorTexture;
                        bind_group_1_binds[binding_number] = gpu.BindGroupEntry{
                            .texture = texture,
                        };
                        // slog.debug("Added bind group entry for binding {d} {any}", .{ binding_number, bind_group_1_binds[binding_number] });
                    }
                }

                // CREATE SHADER PIPE AND BINDINGS
                // ideally this would be done once on startup, but vkdt runs dt_graph_create_shader_module()
                // with the spirv code for each node every frame in dt_graph_run_nodes_allocate()
                slog.debug("Creating shader for node '{s}'", .{node.name});
                var layout_group: [gpu.MAX_BIND_GROUPS]?[gpu.MAX_BINDINGS]?gpu.BindGroupLayoutEntry = @splat(null);
                layout_group[0] = layout_group_0_binding;
                layout_group[1] = layout_group_1_binding;

                const shader = node.shader orelse return error.NodeMissingShaderCode;
                const pipeline = try gpu.ComputePipeline.init(
                    gpu_inst,
                    shader,
                    "main",
                    layout_group,
                );
                node.compute_pipeline = pipeline;

                slog.debug("Creating bindings for node '{s}'", .{node.name});
                var bind_group: [gpu.MAX_BIND_GROUPS]?[gpu.MAX_BINDINGS]?gpu.BindGroupEntry = @splat(null);
                bind_group[0] = bind_group_0_binds;
                bind_group[1] = bind_group_1_binds;

                const bindings = try gpu.Bindings.init(gpu_inst, &pipeline, bind_group);
                // defer bindings.deinit();
                node.bindings = bindings;
            }
        }
    }

    fn runNodesAllocateStagingBuffersForTextures(self: *Pipeline) !void {
        if (self.upload_fba) |*upload_fba| {
            var upload_allocator = upload_fba.allocator();

            // we currently only support one upload in the entire pipeline
            // so we are going check if the first node has a source connector
            const first_node_handle = self.node_execution_order.items[0];
            var first_node_ptr = try self.node_pool.getPtr(first_node_handle);

            slog.debug("First node: '{s}'", .{first_node_ptr.name});

            // TODO: support multiple source uploads in the future
            if (first_node_ptr.sockets[0]) |*sock| {
                if (sock.type == .source) {
                    // typically...
                    // const size_bytes = sock.roi.?.w * sock.roi.?.h * sock.format.bpp();
                    // but I think the stride is aligned to COPY_BYTES_PER_ROW_ALIGNMENT
                    // need to review if this is needed. it initially seemed to work without it
                    const bytes_per_row = sock.roi.?.w * sock.format.bpp();
                    const aligned_bytes_per_row = gpu.alignBytesPerRow(bytes_per_row);
                    const size_bytes = aligned_bytes_per_row * sock.roi.?.h;

                    slog.debug("Allocating {d} bytes upload buffer for source socket '{s} > {s}'", .{ size_bytes, first_node_ptr.name, sock.name });
                    slog.debug("Source socket ROI {any}", .{.{ .w = sock.roi.?.w, .h = sock.roi.?.h }});
                    const mapped_slice = try upload_allocator.alignedAlloc(u8, gpu.COPY_BUFFER_ALIGNMENT, size_bytes);

                    const upload_offset = @intFromPtr(mapped_slice.ptr) - @intFromPtr(upload_fba.ptr);
                    sock.*.staging_offset = upload_offset;
                    const mapped_slice_ptr: *anyopaque = @ptrCast(@alignCast(mapped_slice.ptr));
                    sock.*.staging_ptr = mapped_slice_ptr;
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

            if (last_node_ptr.sockets[0]) |*sock| {
                if (sock.type == .sink) {
                    // typically...
                    // const size_bytes = sock.roi.?.w * sock.roi.?.h * sock.format.bpp();
                    // but I think the stride is aligned to COPY_BYTES_PER_ROW_ALIGNMENT
                    // need to review if this is needed. it initially seemed to work without it
                    const bytes_per_row = sock.roi.?.w * sock.format.bpp();
                    const aligned_bytes_per_row = gpu.alignBytesPerRow(bytes_per_row);
                    const size_bytes = aligned_bytes_per_row * sock.roi.?.h;
                    slog.debug("Allocating {d} bytes download buffer for sink socket '{s} > {s}'", .{ size_bytes, last_node_ptr.name, sock.name });
                    slog.debug("Sink socket ROI {any}", .{.{ .w = sock.roi.?.w, .h = sock.roi.?.h }});
                    const mapped_slice = try download_allocator.alignedAlloc(u8, gpu.COPY_BUFFER_ALIGNMENT, size_bytes);

                    const download_offset = @intFromPtr(mapped_slice.ptr) - @intFromPtr(download_fba.ptr);
                    sock.*.staging_offset = download_offset;
                    const mapped_slice_ptr: *anyopaque = @ptrCast(@alignCast(mapped_slice.ptr));
                    sock.*.staging_ptr = mapped_slice_ptr;
                } else {
                    slog.err("Sink node socket is not of type sink, skipping download", .{});
                    return error.LastNodeInputSocketNotSink;
                }
            }
        }
    }

    pub fn runModulesUploadParams(self: *Pipeline, arena: std.mem.Allocator) !void {
        var upload_buffer = self.upload_buffer orelse return error.PipelineMissingBuffer;

        upload_buffer.map();

        for (self.module_execution_order.items) |module_handle| {
            const module = try self.module_pool.getPtr(module_handle);
            if (module.desc.type == .compute) {
                if (module.enabled == false) continue;

                // upload params
                params: {
                    if (module.param_size == 0 or module.param_size == null) break :params;
                    // extract just ParamValue from params
                    var tu: [api.MAX_PARAMS_PER_MODULE]Param = undefined;
                    var tu_len: usize = 0;
                    for (module.params, 0..) |param, idx| {
                        if (param) |p| {
                            tu[idx] = p;
                            tu_len += 1;
                        }
                    }
                    // if (tu_len == 0) break :params;
                    var buf = try arena.alloc(u8, 1024);
                    defer arena.free(buf);
                    const used_len = try Param.layoutTaggedUnion(buf, tu[0..tu_len]);

                    // slog.debug("Uploading params for module {s}, total size {d} bytes", .{ module.desc.name, list.items.len });
                    // slog.debug("Param bytes for module {s}:", .{module.desc.name});
                    // var buf: [100]u8 = undefined;
                    // var w: std.io.Writer = .fixed(&buf);
                    // for (list.items) |byte| {
                    //     try w.print("{x:0>2} ", .{byte});
                    // }
                    // const printed = w.buffered();
                    // slog.debug("{s}", .{printed});

                    const param_mapped_slice_ptr = module.param_mapped_slice_ptr orelse return error.ModuleMissingParamMappedSlicePtr;
                    const mapped_ptr: [*]u8 = @ptrCast(@alignCast(param_mapped_slice_ptr));
                    @memcpy(mapped_ptr, buf[0..used_len]);
                }

                // upload img params
                if (module.img_param) |img_param| {
                    slog.debug("Uploading img params for module '{s}':", .{module.desc.name});
                    var buf = try arena.alloc(u8, try gpu.data.layoutStruct(null, img_param));
                    defer arena.free(buf);
                    const used_len = try gpu.data.layoutStruct(buf, img_param);

                    const img_param_mapped_slice_ptr = module.img_param_mapped_slice_ptr orelse return error.ModuleMissingImgParamMappedSlicePtr;
                    const mapped_ptr: [*]u8 = @ptrCast(@alignCast(img_param_mapped_slice_ptr));
                    @memcpy(mapped_ptr, buf[0..used_len]);
                }
            }
        }

        upload_buffer.unmap();
    }

    /// Calls module readSource() functions to upload source data to GPU
    /// similar to vkdt dt_graph_run_nodes_upload()
    fn runNodesUploadSource(self: *Pipeline) !void {
        var upload_buffer = self.upload_buffer orelse return error.PipelineMissingBuffer;

        const first_node_handle = self.node_execution_order.items[0];
        const first_node = try self.node_pool.getPtr(first_node_handle);
        if (!self.nodeIsDirty(first_node)) return;

        // find the source socket (the first node may also have other sockets)
        var source_sock: ?*Socket = null;
        for (&first_node.sockets) |*maybe_sock| {
            if (maybe_sock.*) |*sock| {
                if (sock.type == .source) {
                    source_sock = sock;
                    break;
                }
            }
        }
        const sock = source_sock orelse return error.FirstNodeInputSocketNotSource;
        const source_mod = try self.module_pool.getPtr(first_node.mod);
        const readSourceFn = source_mod.desc.readSource orelse return error.NodeMissingReadSourceFunction;

        upload_buffer.map();
        slog.debug("Uploading source data for first node", .{});
        const mapped_ptr = sock.staging_ptr orelse unreachable;
        slog.debug("Calling readSource function for first node", .{});
        try readSourceFn(self, first_node.mod, mapped_ptr);
        upload_buffer.unmap();
    }

    /// Note: this only works when called while traversing node_execution_order
    /// since it will only propogate downstream dirty flags if the very previous
    /// node is dirty. The dirty flag is then memoized so that the next node
    /// in the execution order can look back.
    /// Amortized O(edges-per-dirty-path) thanks to the memoize-on-discover.
    fn nodeIsDirty(self: *Pipeline, node: *Node) bool {
        const mod = self.module_pool.getPtr(node.mod) catch return false;
        if (mod.dirty) return true;

        // walk upstream: any input socket connected to a node whose module is
        // dirty (transitively) makes this module dirty too
        for (node.sockets) |socket| {
            if (socket) |sock| {
                const conn = sock.connected_to_node orelse continue;
                const producer = self.node_pool.getPtr(conn.item) catch continue;
                if (self.nodeIsDirty(producer)) {
                    mod.dirty = true; // memoize so later checks short-circuit
                    return true;
                }
            }
        }
        return false;
    }

    fn markNodeDirty(self: *Pipeline, node: *Node) void {
        const mod = self.module_pool.getPtr(node.mod) catch return;
        mod.dirty = true;
    }

    fn runModulesMarkDirty(self: *Pipeline) void {
        // full rebuild: mark every module; nodes derive dirtiness from them
        var it = self.module_pool.liveHandles();
        while (it.next()) |mod_handle| {
            const mod = self.module_pool.getPtr(mod_handle) catch continue;
            mod.dirty = true;
        }
    }

    fn runModulesClearDirtyFlag(self: *Pipeline) void {
        var it = self.module_pool.liveHandles();
        while (it.next()) |mod_handle| {
            const mod = self.module_pool.getPtr(mod_handle) catch continue;
            mod.dirty = false;
        }
    }

    fn runNodes(self: *Pipeline, options: RunNodesOptions) !void {
        const gpu_inst = self.gpu orelse return error.PipelineNoGPUInstance;
        var upload_buffer = self.upload_buffer orelse return error.PipelineMissingBuffer;
        var download_buffer = self.download_buffer orelse return error.PipelineMissingBuffer;

        var encoder = try gpu.Encoder.start(gpu_inst);
        defer encoder.deinit();

        var nodes_ran: i32 = 0;

        for (self.node_execution_order.items) |node_handle| {
            const node = try self.node_pool.getPtr(node_handle);
            if (options.only_dirty and !self.nodeIsDirty(node)) continue;
            slog.debug("Enqueueing node '{s}'", .{node.name});
            nodes_ran += 1;
            try self.enqueueNode(&encoder, node_handle, node, &upload_buffer, &download_buffer);
            self.perf.recordNodeRun(node);
        }

        slog.debug("Enqueued {d} nodes", .{nodes_ran});

        try gpu_inst.run(encoder.finish());
    }

    fn enqueueNode(
        self: *Pipeline,
        encoder: *gpu.Encoder,
        node_handle: NodeHandle,
        node: *Node,
        upload_buffer: *gpu.Buffer,
        download_buffer: *gpu.Buffer,
    ) !void {
        _ = node_handle;
        node.run_count += 1;
        switch (node.type) {
            .compute => {
                const mod = try self.module_pool.getPtr(node.*.mod);
                if (mod.*.param_handle) |param_handle| {
                    const param_buffer = try self.param_buffer_pool.getPtr(param_handle);
                    var param_buf = param_buffer.* orelse return error.ModuleMissingParamBuffer;
                    const param_offset = mod.*.param_offset orelse return error.ModuleMissingParamBufferOffset;
                    const param_size_bytes = mod.*.param_size orelse return error.ModuleParamBufferSizeNotSet;
                    slog.debug("Enqueueing param buffer at offset {d}", .{param_offset});
                    try encoder.enqueueBufToBuf(upload_buffer, param_offset, &param_buf, 0, param_size_bytes);
                }
                if (mod.*.img_param_handle) |img_param_handle| {
                    const img_param_buffer = try self.param_buffer_pool.getPtr(img_param_handle);
                    var img_param_buf = img_param_buffer.* orelse return error.ModuleMissingImgParamBuffer;
                    const img_param_offset = mod.*.img_param_offset orelse return error.ModuleMissingImgParamBufferOffset;
                    const img_param_size_bytes = mod.*.img_param_size orelse return error.ModuleImgParamBufferSizeNotSet;
                    slog.debug("Enqueueing img param buffer at offset {d}", .{img_param_offset});
                    try encoder.enqueueBufToBuf(upload_buffer, img_param_offset, &img_param_buf, 0, img_param_size_bytes);
                }
                var compute_pipeline = node.compute_pipeline orelse return error.NodeMissingShader;
                var bindings = node.bindings orelse return error.NodeMissingBindings;
                slog.debug("Enqueueing compute shader for node '{s}'", .{node.name});
                encoder.enqueueShader(
                    &compute_pipeline,
                    &bindings,
                    node.run_size.?,
                );
            },
            .source => {
                slog.debug("Enqueueing source node '{s}' buffer to texture copy", .{node.name});
                var tex = node.sockets[0].?.texture orelse return error.PipelineMissingSourceNodeTexture;
                const staging_offset = node.sockets[0].?.staging_offset orelse unreachable;
                const roi = node.sockets[0].?.roi orelse unreachable;
                slog.debug("Source node staging offset: {d}", .{staging_offset});
                try encoder.enqueueBufToTex(upload_buffer, staging_offset, &tex, roi);
            },
            .sink => {
                slog.debug("Enqueueing sink node '{s}' texture to buffer copy", .{node.name});
                // const connector = try self.connector_pool.getPtr(self.getNodeSocketTexture(node.sockets[0].?) orelse return error.NodeOutputSocketMissingConnectorHandle);
                // var tex = connector.*.texture orelse return error.PipelineMissingSinkNodeTexture;
                // var tex = node.sockets[0].?.texture orelse return error.PipelineMissingSinkNodeTexture;
                var tex = self.getNodeSocketTexture(node.sockets[0].?) orelse return error.PipelineMissingSinkNodeTexture;
                const staging_offset = node.sockets[0].?.staging_offset orelse unreachable;
                slog.debug("Sink node staging offset: {d}", .{staging_offset});
                const roi = node.sockets[0].?.roi orelse unreachable;
                try encoder.enqueueTexToBuf(download_buffer, staging_offset, &tex, roi);
            },
        }
    }

    /// Download the sink texture to CPU and call the sink module's writeSink.
    /// NOTE: allocates a full trimmed copy (`mapped_trimmed`) every dirty frame
    /// to strip row padding — biggest per-frame allocation in the hot path.
    fn runNodesDownloadSink(self: *Pipeline) !void {
        var download_buffer = self.download_buffer orelse return error.PipelineMissingBuffer;

        // we currently only support one download in the entire pipeline
        // so we are going check if the last node has a sink connector
        // TODO: run all o- nodes
        const last_node_handle = self.node_execution_order.items[self.node_execution_order.items.len - 1];
        var last_node = try self.node_pool.getPtr(last_node_handle);

        // if last node is o-display, just return
        if (std.mem.eql(u8, last_node.name, "o-display")) {
            return;
        }
        download_buffer.map();
        if (last_node.sockets[0]) |*sock| {
            if (sock.type == .sink) {
                const last_node_mod = try self.module_pool.getPtr(last_node.*.mod);
                if (last_node_mod.desc.writeSink) |writeSinkFn| {
                    slog.debug("Downloading sink data for last node", .{});
                    const mapped_ptr = sock.*.staging_ptr orelse unreachable;

                    // we are going to help out the module author by removing the padding bytes if they exist since wgpu
                    // requires bytes per row to be aligned to 256 bytes, but this is not ideal since it requires an extra
                    // copy and extra memory allocation. in the future, we should consider allowing users to handle the
                    // padding themselves in their writeSink function by providing them with the aligned bytes per row and
                    // the total size of the mapped buffer.
                    const mapped_trimmed = try self.allocator.alloc(u8, sock.roi.?.w * sock.roi.?.h * sock.format.bpp());
                    defer self.allocator.free(mapped_trimmed);
                    {
                        // wgpu requires bytes per row to be aligned to 256 bytes, so we need to remove the padding bytes if they exist
                        const bytes_per_row = sock.roi.?.w * sock.format.bpp();
                        const aligned_bytes_per_row = gpu.alignBytesPerRow(bytes_per_row);

                        const aligned_size_bytes = aligned_bytes_per_row * sock.roi.?.h;
                        const download_buffer_padded_ptr: [*]u8 = @ptrCast(@alignCast(mapped_ptr));
                        const download_buffer_padded_slice = download_buffer_padded_ptr[0..aligned_size_bytes];

                        // copy each row of the byte array with the aligned bytes per row to the output slice
                        for (0..sock.roi.?.h) |row| {
                            const src_start = row * aligned_bytes_per_row;
                            const src_end = src_start + bytes_per_row;
                            const dst_start = row * bytes_per_row;
                            const dst_end = dst_start + bytes_per_row;
                            @memcpy(mapped_trimmed[dst_start..dst_end], download_buffer_padded_slice[src_start..src_end]);
                        }
                    }

                    try writeSinkFn(self.allocator, self.io, self, last_node.mod, mapped_trimmed.ptr);
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

    fn runModulesDeinit(self: *Pipeline) void {
        for (self.module_execution_order.items) |module_handle| {
            const module = self.module_pool.getPtr(module_handle) catch unreachable;
            if (module.desc.deinit) |deinitFn| {
                deinitFn(self.allocator, self, module_handle);
            }
        }
    }

    fn runModulesDeinitParams(self: *Pipeline) void {
        var module_pool_handles = self.module_pool.liveHandles();
        while (module_pool_handles.next()) |module_handle| {
            var module = self.module_pool.getPtr(module_handle) catch unreachable;
            for (&module.params) |*maybe_param_ptr| {
                var maybe_param = maybe_param_ptr.*;
                if (maybe_param) |*param| {
                    param.deinit(self.allocator);
                }
            }
        }
    }
};

/// stack-based DFS iterator for traversing DAGs stored in a Pool
/// each element T must have a `desc` field in which there is a `sockets` field
/// each socket must have a `private.connected_to_node` field which is an optional connection to another node handle
pub fn PooledDagDfsIterator(T: type) type {
    return struct {
        pub fn iterator(allocator: std.mem.Allocator, pool: *Pool(T)) !DagDfsIterator {
            // Map from `id` to `mark` value
            var mark = std.AutoHashMap(Pool(T).Handle, u8).init(allocator);
            errdefer mark.deinit();

            // Stack to hold node IDs
            var stack = try std.ArrayList(Pool(T).Handle).initCapacity(allocator, 1024);
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
                const node = try pool.getPtr(node_handle);
                for (node.sockets) |socket| {
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
            stack: std.ArrayList(Pool(T).Handle),
            sp: isize,
            mark: std.AutoHashMap(Pool(T).Handle, u8),
            node_pool: *Pool(T),

            pub fn deinit(it: *DagDfsIterator) void {
                it.stack.deinit(it.allocator);
                it.mark.deinit();
            }

            pub fn next(it: *DagDfsIterator) !?Pool(T).Handle {
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
                        for (curr_node.sockets) |child_socket| {
                            const socket = child_socket orelse continue;
                            const maybe_connected_to = if (comptime T == Node) socket.connected_to_node else if (comptime T == Module) socket.connected_to_module else unreachable;
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
/// Runs on reroute only (module+node execution order). O(vertices + edges).
pub fn buildGraph(
    T: type,
    pool: *Pool(T),
    graph: *DirectedGraph(Pool(T).Handle, ConnectorHandle(Pool(T).Handle), std.hash_map.AutoContext(Pool(T).Handle)),
) !void {
    var pool_handles = pool.liveHandles();
    while (pool_handles.next()) |dst_node_handle| {
        const dst_node = try pool.getPtr(dst_node_handle);
        for (dst_node.sockets) |socket| {
            if (socket) |sock| {
                const maybe_connected_to = if (comptime T == Node) sock.connected_to_node else if (comptime T == Module) sock.connected_to_module else unreachable;
                const src_node_handle_connection = maybe_connected_to orelse continue;
                const src_node_handle = src_node_handle_connection.item;
                // connect
                try graph.add(dst_node_handle);
                try graph.add(src_node_handle);
                const connection: ConnectorHandle(Pool(T).Handle) = .{
                    .item = src_node_handle,
                    .socket_idx = src_node_handle_connection.socket_idx,
                };
                try graph.addEdge(src_node_handle, dst_node_handle, connection);
            }
        }
    }
}
