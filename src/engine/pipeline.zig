const std = @import("std");
const gpu = @import("gpu.zig");
const ROI = @import("ROI.zig");
const api = @import("api.zig");
const Pool = @import("zpool").Pool;
const slog = std.log.scoped(.pipe);

// const ModulePool = Pool(16, 16, gpu.Texture, struct {
//     ptr: gpu.Texture,
//     info: api.Module,
// });
// const ModuleHandle = ModulePool.Handle;

pub const ConnectorDesc = struct {
    name: []const u8,
    format: gpu.TextureFormat,
    roi: ?ROI,
};

const ConnectorPool = Pool(16, 16, gpu.Texture, struct {
    ptr: ?gpu.Texture,
    info: ConnectorDesc,
});
const ConnectorHandle = ConnectorPool.Handle;

pub const Module = struct {
    desc: api.ModuleDesc,
    enabled: bool,

    // are these needed? vkdt doesn't have them
    input_conn_handle: ?ConnectorHandle,
    output_conn_handle: ?ConnectorHandle,

    pub fn init(
        pipe: *Pipeline,
        desc: api.ModuleDesc,
    ) !Module {
        _ = pipe;
        return Module{
            .desc = desc,
            .enabled = true,
            .input_conn_handle = null,
            .output_conn_handle = null,
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
    mod: ?*Module,
    shader: gpu.ShaderPipe,

    input_conn_handle: ?ConnectorHandle,
    output_conn_handle: ?ConnectorHandle,
    bindings: ?gpu.Bindings,

    pub fn init(
        pipe: *Pipeline,
        mod: *Module,
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
                    .type = desc.input_sock.type.toShaderPipeConnType(),
                    .format = desc.input_sock.format,
                },
                .{
                    .binding = 1,
                    .type = desc.output_sock.type.toShaderPipeConnType(),
                    .format = desc.output_sock.format,
                },
            },
        );
        return Node{
            .desc = desc,
            .mod = mod,
            .shader = shader,
            .input_conn_handle = null,
            .output_conn_handle = null,
            .bindings = null,
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
    modules: std.ArrayList(Module),
    // modules_pool: std.heap.MemoryPoolExtra(Module, .{}),
    connector_pool: ConnectorPool,

    pub fn init(allocator: std.mem.Allocator, gpu_instance: *gpu.GPU) !Pipeline {
        var gpu_allocator = try gpu.GPUAllocator.init(gpu_instance, null);
        errdefer gpu_allocator.deinit();

        const modules = std.ArrayList(Module).initCapacity(allocator, MAX_MODULES) catch unreachable;
        errdefer modules.deinit();

        // var modules_pool = std.heap.MemoryPoolExtra(api.Module, .{}).init(allocator);
        // errdefer modules_pool.deinit();

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
        // loop through connectors and deinit textures
        var live_connector_handles = self.connector_pool.liveHandles();
        while (live_connector_handles.next()) |connector| {
            var t: gpu.Texture = self.connector_pool.getColumn(connector, .ptr) catch continue orelse continue;
            t.deinit();
        }
        self.connector_pool.deinit();

        self.gpu_allocator.deinit();
        self.nodes.deinit(self.allocator);
        self.modules.deinit(self.allocator);
    }

    pub fn addNodeDesc(self: *Pipeline, mod: *Module, node_desc: api.NodeDesc) !*Node {
        slog.info("Adding node with shader entry point: {s}", .{node_desc.entry_point});
        // TODO: check input connection to mach previous node output connection
        const node = try Node.init(self, mod, node_desc);

        node.input_conn_handle = try self.connector_pool.add(.{
            .ptr = null,
            .info = node.desc.input_sock,
        });
        node.output_conn_handle = try self.connector_pool.add(.{
            .ptr = null,
            .info = node.desc.output_sock,
        });

        try self.nodes.append(self.allocator, node);

        return &self.nodes.items[self.nodes.items.len - 1];
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

    pub fn addModuleDesc(self: *Pipeline, module_desc: api.ModuleDesc) !*Module {
        slog.info("Adding module: {s}", .{module_desc.name});
        const module = try Module.init(self, module_desc);
        try self.modules.append(self.allocator, module);
        return &self.modules.items[self.modules.items.len - 1];
    }

    pub fn printModules(self: *Pipeline) void {
        for (self.modules.items) |module| {
            // slog.info("Module: {s}, enabled: {any}", .{ module.desc.name, module.enabled });
            const module_text =
                \\ ==== MODULE ======================================
                \\  Input Connector:  {any}
                \\  Input Socket:     "{s}", {any}, {any}, {any}
                \\  Name:             "{s}"
                \\  Enabled:          {any}
                \\  Output Socket:    "{s}", {any}, {any}, {any}
                \\  Output Connector: {any}
                \\ ==================================================
                \\
            ;
            const input_texture = if (module.input_conn_handle) |handle| self.connector_pool.getColumn(handle, .ptr) catch unreachable else null;
            const output_texture = if (module.output_conn_handle) |handle| self.connector_pool.getColumn(handle, .ptr) catch unreachable else null;
            std.debug.print(module_text, .{
                if (input_texture) |input_tex| input_tex.texture else null,
                if (module.desc.input_sock) |input_sock| input_sock.name else "null",
                if (module.desc.input_sock) |input_sock| input_sock.type else null,
                if (module.desc.input_sock) |input_sock| input_sock.format else null,
                if (module.desc.input_sock) |input_sock| input_sock.roi else null,
                module.desc.name,
                module.enabled,
                if (module.desc.output_sock) |output_sock| output_sock.name else "null",
                if (module.desc.output_sock) |output_sock| output_sock.type else null,
                if (module.desc.output_sock) |output_sock| output_sock.format else null,
                if (module.desc.output_sock) |output_sock| output_sock.roi else null,
                if (output_texture) |output_tex| output_tex.texture else null,
            });
        }
    }
    pub fn printNodes(self: *Pipeline) void {
        for (self.nodes.items) |node| {
            // slog.info("Node: {s}", .{node.desc.entry_point});
            // std.debug.print("Hello, {s}!\n", .{"World"});

            const node_text =
                \\ ==== NODE ========================================
                \\  Input Connector:  {any}
                \\  Input Socket:     "{s}", {any}, {any}, {any}
                \\  Entry Point:      "{s}" ({s})
                \\  Output Socket:    "{s}", {any}, {any}, {any}
                \\  Output Connector: {any}
                \\ ==================================================
                \\
            ;
            const input_texture = self.connector_pool.getColumn(node.input_conn_handle.?, .ptr) catch unreachable;
            const output_texture = self.connector_pool.getColumn(node.output_conn_handle.?, .ptr) catch unreachable;
            std.debug.print(node_text, .{
                input_texture.?.texture,
                node.desc.input_sock.name,
                node.desc.input_sock.type,
                node.desc.input_sock.format,
                node.desc.input_sock.roi,
                node.desc.entry_point,
                @tagName(node.desc.type),
                node.desc.output_sock.name,
                node.desc.output_sock.type,
                node.desc.output_sock.format,
                node.desc.output_sock.roi,
                output_texture.?.texture,
            });
        }
    }

    pub fn checkModules(self: *Pipeline) !void {
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

    pub fn runModules(self: *Pipeline) !void {

        // configure input sockets and output sockets
        var prev_roi: ?ROI = null;
        for (self.modules.items) |*module| {
            slog.info("Configuring sockets for module: {s}", .{module.desc.name});
            if (module.enabled == false) continue;

            // if the input socket is not set, use the previous module's output socket
            if (module.desc.type != .source) {
                // TODO: check connection first
                if (prev_roi != null) {
                    slog.info("Module {s} input sock ROI set to previous output sock ROI", .{module.desc.name});
                    module.desc.input_sock.?.roi = prev_roi;
                } else {
                    slog.err("Module {s} has no input sock ROI and no previous module to get it from", .{module.desc.name});
                    return error.ModuleMissingInputSockROI;
                }
            }

            // if the module has a modify_roi_out function, call it
            // else copy roi from input to output
            if (module.desc.modify_roi_out) |modify_roi_out_fn| {
                slog.info("Modifying output sock ROI for module: {s}", .{module.desc.name});
                try modify_roi_out_fn(self, module);
            } else {
                slog.info("No modify_roi_out function for module: {s}", .{module.desc.name});
                // set roi out to roi in
                if (module.desc.type != .source) {
                    slog.info("Setting output ROI to input ROI for module: {s} to {any}", .{ module.desc.name, module.desc.input_sock.?.roi });
                    module.desc.output_sock.?.roi = module.desc.input_sock.?.roi;
                }
            }
            // update prev_roi
            if (module.desc.output_sock != null) {
                prev_roi = module.desc.output_sock.?.roi;
            } else {
                slog.info("Module {s} has no output sock, not updating prev_roi", .{module.desc.name});
                return error.ModuleMissingOutputSockROI;
            }
        }

        // allocate images only for module output connectors
        var prev_conn_handle: ?ConnectorHandle = null;
        for (self.modules.items) |*module| {
            slog.info("Configuring sockets for module: {s}", .{module.desc.name});
            if (module.enabled == false) continue;

            // if the input socket is not set, use the previous module's output socket
            if (module.desc.type != .source) {
                if (prev_conn_handle != null) {
                    slog.info("Module {s} input connector set to previous output connector", .{module.desc.name});
                    module.input_conn_handle = prev_conn_handle;
                } else {
                    slog.err("Module {s} has no input connector and no previous module to get it from", .{module.desc.name});
                    return error.ModuleMissingInputSock;
                }
            }

            // TODO: check output connectors before allocating

            // once the output connector is defined, allocate image for it
            if (module.desc.output_sock != null) {
                slog.info("Allocating output connector image for module: {s}", .{module.desc.name});
                slog.info("Output: {any}", .{module.desc.output_sock});
                const texture_out = try gpu.Texture.init(self.gpu, module.desc.output_sock.?.format, module.desc.output_sock.?.roi.?);
                const connector_desc: ConnectorDesc = .{
                    .name = module.desc.output_sock.?.name,
                    .format = module.desc.output_sock.?.format,
                    .roi = module.desc.output_sock.?.roi,
                };
                module.output_conn_handle = try self.connector_pool.add(.{
                    .ptr = texture_out,
                    .info = connector_desc,
                });
                prev_conn_handle = module.output_conn_handle;
            }
        }

        // CREATE NODES
        for (self.modules.items) |*module| {
            if (module.enabled == false) continue;
            if (module.desc.create_nodes) |create_nodes_fn| {
                try create_nodes_fn(self, module);
            }
        }
    }

    // dt_graph_run_nodes_allocate
    pub fn runNodesAllocate(self: *Pipeline) !void {
        // PASS #1 - allocate output buffers and create compute shaders for each node

        var prev_conn_handle: ?ConnectorHandle = null;
        var prev_sock: ?api.SocketDesc = null;
        for (self.nodes.items) |*node| {
            slog.info("Creating step for node with shader entry point: {s}", .{node.desc.entry_point});

            // if the input socket is not set, use the previous module's output socket
            if (node.output_conn_handle == null) {
                if (prev_sock != null) {
                    slog.info("Node {s} input sock set to previous output sock", .{node.desc.entry_point});
                    node.desc.input_sock = prev_sock orelse return error.NodeMissingInputSock;
                    node.input_conn_handle = prev_conn_handle;
                } else {
                    slog.err("Node {s} has no input sock and no previous module to get it from", .{node.desc.entry_point});
                    return error.NodeMissingInputSock;
                }
            }

            if (node.output_conn_handle == null) {
                slog.info("Node {s} has no output connector", .{node.desc.entry_point});
                node.output_conn_handle = self.connector_pool.add(.{
                    .ptr = null,
                    .info = .{
                        .name = node.desc.output_sock.name,
                        .format = node.desc.output_sock.format,
                        .roi = node.desc.output_sock.roi,
                    },
                }) catch unreachable;
                prev_sock = node.desc.output_sock;
                prev_conn_handle = node.output_conn_handle;
            }

            var texture_in = try self.connector_pool.getColumn(node.input_conn_handle.?, .ptr) orelse return error.NodeMissingInputTexture;
            var texture_out = try self.connector_pool.getColumn(node.output_conn_handle.?, .ptr) orelse return error.NodeMissingOutputTexture;

            const bindings = try gpu.Bindings.init(self.gpu, &node.shader, &texture_in, &texture_out);
            // defer bindings.deinit();
            node.bindings = bindings;
        }
    }

    pub fn runNodesUpload(self: *Pipeline) !void {
        // we currently only support one upload in the entire pipeline
        // so we are going check if the first module has a source connector
        const first_module = self.modules.items[0];
        if (first_module.desc.input_sock) |input_sock| {
            if (input_sock.type == .source) {
                slog.info("Uploading source data for first module", .{});
            } else {
                slog.err("First module input socket is not of type source, skipping upload", .{});
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
        self.checkModules() catch unreachable;
        self.runModules() catch unreachable;

        // then run nodes
        self.runNodesAllocate() catch unreachable;
        self.runNodesUpload() catch unreachable;

        self.printModules();
        self.printNodes();

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
