const std = @import("std");
const pipeline = @import("pipeline.zig");
const gpu = @import("gpu");

const ModulePool = pipeline.ModulePool;
const Node = @import("Node.zig");
const NodePool = pipeline.NodePool;

const Connector = @import("Connector.zig");
// const ConnectorPool = pipeline.ConnectorPool;

pub const PerfMetrics = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    /// Print the per-run report and collect the (more expensive) per-node
    /// timings. Set from `PipelineConfig.perf_report`.
    enabled: bool = false,

    start_time: std.Io.Timestamp,
    time_keys: std.ArrayList([]const u8),
    times: std.StringHashMap(u64),

    node_run_counts: std.AutoHashMap(pipeline.NodeHandle, u32),
    /// CPU time spent enqueueing each node this run; cleared by `startRun`.
    node_cpu_ns: std.AutoHashMap(pipeline.NodeHandle, NodeTiming),

    upload_buffer_size_bytes: ?usize,
    upload_buffer_usage_size_bytes: ?usize,
    download_buffer_size_bytes: ?usize,
    download_buffer_usage_size_bytes: ?usize,

    n_nodes_ran: ?usize,
    n_connector_textures_created: ?usize,
    n_pipelines_created: ?usize,
    n_bindings_created: ?usize,
    n_param_uploads: ?usize,
    n_img_param_uploads: ?usize,
    n_param_copies: ?usize,

    number_of_modules: ?usize,
    number_of_nodes: ?usize,
    number_of_connectors: ?usize,

    pub const NodeTiming = struct {
        name: []const u8 = "",
        ns: u64 = 0,
    };

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, io: std.Io, enabled: bool) !PerfMetrics {
        return PerfMetrics{
            .allocator = allocator,
            .io = io,
            .enabled = enabled,
            // .timer = undefined,
            .start_time = .zero,
            .time_keys = try std.ArrayList([]const u8).initCapacity(allocator, 16),
            .times = std.StringHashMap(u64).init(allocator),
            .node_run_counts = std.AutoHashMap(pipeline.NodeHandle, u32).init(allocator),
            .node_cpu_ns = std.AutoHashMap(pipeline.NodeHandle, NodeTiming).init(allocator),
            .upload_buffer_size_bytes = null,
            .upload_buffer_usage_size_bytes = null,
            .download_buffer_size_bytes = null,
            .download_buffer_usage_size_bytes = null,
            .n_nodes_ran = null,
            .n_connector_textures_created = null,
            .n_pipelines_created = null,
            .n_bindings_created = null,
            .n_param_uploads = null,
            .n_img_param_uploads = null,
            .n_param_copies = null,
            .number_of_modules = null,
            .number_of_nodes = null,
            .number_of_connectors = null,
        };
    }

    pub fn deinit(self: *PerfMetrics) void {
        self.times.deinit();
        self.node_run_counts.deinit();
        self.node_cpu_ns.deinit();
        self.time_keys.deinit(self.allocator);
    }

    /// Start/Stop
    pub fn startRun(self: *PerfMetrics) !void {
        try self.timerStart();
        self.resetCounters();
        self.node_cpu_ns.clearRetainingCapacity();
    }

    /// TIMER
    pub fn timerStart(self: *PerfMetrics) !void {
        self.time_keys.clearAndFree(self.allocator);
        self.times.clearAndFree();
        self.start_time = std.Io.Clock.awake.now(self.io);
    }

    pub fn timerLap(self: *PerfMetrics, name: []const u8) !void {
        const elapsed_ns = self.start_time.untilNow(self.io, .awake).toNanoseconds();
        _ = try self.times.put(name, @intCast(elapsed_ns));
        try self.time_keys.append(self.allocator, name);
        self.start_time = std.Io.Clock.awake.now(self.io);
    }

    /// BUFFER
    pub fn recordUploadBufferUsage(self: *PerfMetrics, upload_fba: ?gpu.Buffer.Allocator) void {
        self.upload_buffer_size_bytes = if (upload_fba) |*fba| fba.size else 0;
        self.upload_buffer_usage_size_bytes = if (upload_fba) |*fba| fba.size - fba.totalFreeSpace() else 0;
    }
    pub fn recordDownloadBufferUsage(self: *PerfMetrics, download_fba: ?gpu.Buffer.Allocator) void {
        self.download_buffer_size_bytes = if (download_fba) |*fba| fba.size else 0;
        self.download_buffer_usage_size_bytes = if (download_fba) |*fba| fba.size - fba.totalFreeSpace() else 0;
    }

    /// POOL
    pub fn countModules(self: *PerfMetrics, module_pool: *ModulePool) void {
        self.number_of_modules = 0;
        var mod_pool_handles = module_pool.liveHandles();
        while (mod_pool_handles.next()) |_| {
            self.number_of_modules.? += 1;
        }
    }

    pub fn countNodes(self: *PerfMetrics, node_pool: *NodePool) void {
        self.number_of_nodes = 0;
        var node_pool_handles = node_pool.liveHandles();
        while (node_pool_handles.next()) |_| {
            self.number_of_nodes.? += 1;
        }
    }

    // pub fn countConnectors(self: *PerfMetrics, connector_pool: *ConnectorPool) void {
    //     self.number_of_connectors = 0;
    //     var conn_pool_handles = connector_pool.liveHandles();
    //     while (conn_pool_handles.next()) |_| {
    //         self.number_of_connectors.? += 1;
    //     }
    // }

    /// Counters
    pub fn resetCounters(self: *PerfMetrics) void {
        self.n_nodes_ran = null;
        self.n_connector_textures_created = null;
        self.n_pipelines_created = null;
        self.n_bindings_created = null;
        self.n_param_uploads = null;
        self.n_img_param_uploads = null;
        self.n_param_copies = null;
    }

    /// Count one dispatch of `node_handle`: bumps the per-run total and this
    /// node's lifetime counter, and accumulates the CPU time spent enqueueing
    /// it (`cpu_ns`, from the stopwatch in `runNodes`).
    pub fn recordNodeRun(
        self: *PerfMetrics,
        node_handle: pipeline.NodeHandle,
        node_name: []const u8,
        cpu_ns: u64,
    ) !void {
        if (self.n_nodes_ran) |*n| {
            n.* += 1;
        } else {
            self.n_nodes_ran = 1;
        }
        const entry = try self.node_run_counts.getOrPut(node_handle);
        entry.value_ptr.* = if (entry.found_existing) entry.value_ptr.* + 1 else 1;

        if (self.enabled) {
            const timing = try self.node_cpu_ns.getOrPut(node_handle);
            if (!timing.found_existing) timing.value_ptr.* = .{ .name = node_name };
            timing.value_ptr.ns += cpu_ns;
        }
    }

    /// Number of times `node_handle` has been dispatched.
    pub fn runCount(self: *const PerfMetrics, node_handle: pipeline.NodeHandle) u32 {
        return self.node_run_counts.get(node_handle) orelse 0;
    }

    /// Drop the counter for a node that no longer exists.
    pub fn forgetNode(self: *PerfMetrics, node_handle: pipeline.NodeHandle) void {
        _ = self.node_run_counts.remove(node_handle);
        _ = self.node_cpu_ns.remove(node_handle);
    }

    pub fn recordConnectorTextureAllocation(self: *PerfMetrics) void {
        if (self.n_connector_textures_created) |*n| {
            n.* += 1;
        } else {
            self.n_connector_textures_created = 1;
        }
    }

    /// Count one `gpu.ComputePipeline.init` for a node this run.
    pub fn recordPipelineCreated(self: *PerfMetrics) void {
        if (self.n_pipelines_created) |*n| {
            n.* += 1;
        } else {
            self.n_pipelines_created = 1;
        }
    }

    /// Count one `gpu.Bindings.init` for a node this run.
    pub fn recordBindingsCreated(self: *PerfMetrics) void {
        if (self.n_bindings_created) |*n| {
            n.* += 1;
        } else {
            self.n_bindings_created = 1;
        }
    }

    /// Count one module whose parameter storage buffer was staged this run.
    pub fn recordParamUpload(self: *PerfMetrics) void {
        if (self.n_param_uploads) |*n| {
            n.* += 1;
        } else {
            self.n_param_uploads = 1;
        }
    }

    /// Count one module whose `ImgParams` uniform was staged this run.
    pub fn recordImgParamUpload(self: *PerfMetrics) void {
        if (self.n_img_param_uploads) |*n| {
            n.* += 1;
        } else {
            self.n_img_param_uploads = 1;
        }
    }

    /// Count one staging→GPU copy of a module's parameter buffer this run.
    pub fn recordParamCopy(self: *PerfMetrics) void {
        if (self.n_param_copies) |*n| {
            n.* += 1;
        } else {
            self.n_param_copies = 1;
        }
    }

    /// Print the performance report.
    pub fn printReportPrintFn(comptime fmt: []const u8, args: anytype) void {
        std.debug.print(fmt ++ "\n", args);
    }

    pub fn printReport(self: *PerfMetrics) void {
        // disabled unless `--perf` (PipelineConfig.perf_report) was requested
        if (!self.enabled) return;

        // const printFn = std.debug.print;
        // const printFn = slog.info;
        const printFn = printReportPrintFn;

        var total_time_ns: f64 = 0;

        var it = self.times.iterator();
        while (it.next()) |entry| {
            total_time_ns += @as(f64, @floatFromInt(entry.value_ptr.*));
        }

        printFn("Pipeline Performance Report:", .{});
        for (self.time_keys.items) |key| {
            const entry = self.times.getPtr(key) orelse continue;
            printFn(" {d: >5.2}% {d: >8.2} ms  {s}", .{
                @as(f64, @floatFromInt(entry.*)) / total_time_ns * 100.0,
                @as(f64, @floatFromInt(entry.*)) / std.time.ns_per_ms,
                key,
            });
        }
        printFn(" Total time: {d:.2} ms  (<33.33 ms for 30fps, <16.67 ms for 60fps)", .{total_time_ns / std.time.ns_per_ms});

        const upload_buffer_usage_size_bytes = self.upload_buffer_usage_size_bytes orelse 0;
        const upload_buffer_size_bytes = self.upload_buffer_size_bytes orelse 0;
        const download_buffer_usage_size_bytes = self.download_buffer_usage_size_bytes orelse 0;
        const download_buffer_size_bytes = self.download_buffer_size_bytes orelse 0;
        printFn(" {d: >5.2}% {B:>6.2}/{B:.2}  {s}", .{
            @as(f64, @floatFromInt(upload_buffer_usage_size_bytes)) / @as(f64, @floatFromInt(upload_buffer_size_bytes)) * 100.0,
            upload_buffer_usage_size_bytes,
            upload_buffer_size_bytes,
            "upload_buffer_size_bytes",
        });
        printFn(" {d: >5.2}% {B:>6.2}/{B:.2}  {s}", .{
            @as(f64, @floatFromInt(download_buffer_usage_size_bytes)) / @as(f64, @floatFromInt(download_buffer_size_bytes)) * 100.0,
            download_buffer_usage_size_bytes,
            download_buffer_size_bytes,
            "download_buffer_size_bytes",
        });
        const n_nodes_ran = self.n_nodes_ran orelse 0;
        const n_connector_textures_created = self.n_connector_textures_created orelse 0;
        printFn(" {d: >5.2}% {d}/{d} nodes ran", .{
            @as(f64, @floatFromInt(n_nodes_ran)) / @as(f64, @floatFromInt(self.number_of_nodes orelse 1)) * 100.0,
            n_nodes_ran,
            self.number_of_nodes orelse 0,
        });
        printFn(" {d: >5.2}% {d}/{d} connector resources created", .{
            @as(f64, @floatFromInt(n_connector_textures_created)) / @as(f64, @floatFromInt(self.number_of_connectors orelse 1)) * 100.0,
            n_connector_textures_created,
            self.number_of_connectors orelse 0,
        });
        printFn(" {d}/{d} pipelines, {d}/{d} bind groups created", .{
            self.n_pipelines_created orelse 0,
            self.number_of_nodes orelse 0,
            self.n_bindings_created orelse 0,
            self.number_of_nodes orelse 0,
        });
        printFn(" {d} param uploads, {d} img_param uploads, {d} param copies", .{
            self.n_param_uploads orelse 0,
            self.n_img_param_uploads orelse 0,
            self.n_param_copies orelse 0,
        });
        printFn(" {d} modules", .{self.number_of_modules orelse 0});
        printFn(" {d} nodes", .{self.number_of_nodes orelse 0});
        printFn(" {d} connectors", .{self.number_of_connectors orelse 0});

        // per-node stopwatch, sorted slowest first
        if (self.node_cpu_ns.count() > 0) {
            const Entry = struct { name: []const u8, ns: u64 };
            var entries = std.ArrayList(Entry).initCapacity(self.allocator, self.node_cpu_ns.count()) catch return;
            defer entries.deinit(self.allocator);
            var node_it = self.node_cpu_ns.valueIterator();
            while (node_it.next()) |timing| {
                entries.appendAssumeCapacity(.{ .name = timing.name, .ns = timing.ns });
            }
            std.mem.sort(Entry, entries.items, {}, struct {
                fn lessThan(_: void, a: Entry, b: Entry) bool {
                    return a.ns > b.ns;
                }
            }.lessThan);
            printFn(" Per-node CPU time:", .{});
            for (entries.items) |entry| {
                printFn("  {d: >8.3} ms  {s}", .{
                    @as(f64, @floatFromInt(entry.ns)) / std.time.ns_per_ms,
                    entry.name,
                });
            }
        }
    }
};
