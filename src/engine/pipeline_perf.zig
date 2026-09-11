const std = @import("std");
const pipeline = @import("pipeline.zig");
const gpu = @import("gpu/root.zig");

const ModulePool = pipeline.ModulePool;
const Node = @import("Node.zig");
const NodePool = pipeline.NodePool;

const Connector = @import("Connector.zig");
const ConnectorPool = pipeline.ConnectorPool;

pub const PerfMetrics = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    start_time: std.Io.Timestamp,
    time_keys: std.ArrayList([]const u8),
    times: std.StringHashMap(u64),

    upload_buffer_size_bytes: ?usize,
    upload_buffer_usage_size_bytes: ?usize,
    download_buffer_size_bytes: ?usize,
    download_buffer_usage_size_bytes: ?usize,

    n_nodes_ran: ?usize,
    n_connector_textures_created: ?usize,

    number_of_modules: ?usize,
    number_of_nodes: ?usize,
    number_of_connectors: ?usize,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !PerfMetrics {
        return PerfMetrics{
            .allocator = allocator,
            .io = io,
            // .timer = undefined,
            .start_time = .zero,
            .time_keys = try std.ArrayList([]const u8).initCapacity(allocator, 16),
            .times = std.StringHashMap(u64).init(allocator),
            .upload_buffer_size_bytes = null,
            .upload_buffer_usage_size_bytes = null,
            .download_buffer_size_bytes = null,
            .download_buffer_usage_size_bytes = null,
            .n_nodes_ran = null,
            .n_connector_textures_created = null,
            .number_of_modules = null,
            .number_of_nodes = null,
            .number_of_connectors = null,
        };
    }

    pub fn deinit(self: *PerfMetrics) void {
        self.times.deinit();
        self.time_keys.deinit(self.allocator);
    }

    /// Start/Stop
    pub fn startRun(self: *PerfMetrics) !void {
        try self.timerStart();
        self.resetCounters();
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

    pub fn countConnectors(self: *PerfMetrics, connector_pool: *ConnectorPool) void {
        self.number_of_connectors = 0;
        var conn_pool_handles = connector_pool.liveHandles();
        while (conn_pool_handles.next()) |_| {
            self.number_of_connectors.? += 1;
        }
    }

    /// Counters
    pub fn resetCounters(self: *PerfMetrics) void {
        self.n_nodes_ran = null;
        self.n_connector_textures_created = null;
    }

    pub fn recordNodeRun(self: *PerfMetrics, node: *Node) void {
        _ = node;
        if (self.n_nodes_ran) |*n| {
            n.* += 1;
        } else {
            self.n_nodes_ran = 1;
        }
    }

    pub fn recordConnectorTextureAllocation(self: *PerfMetrics, conn: *Connector) void {
        _ = conn;
        if (self.n_connector_textures_created) |*n| {
            n.* += 1;
        } else {
            self.n_connector_textures_created = 1;
        }
    }

    /// Print the performance report.
    pub fn printReportPrintFn(comptime fmt: []const u8, args: anytype) void {
        std.debug.print(fmt ++ "\n", args);
    }

    pub fn printReport(self: *PerfMetrics) void {
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
        printFn(" {d: >5.2}% {d}/{d} connector textures created", .{
            @as(f64, @floatFromInt(n_connector_textures_created)) / @as(f64, @floatFromInt(self.number_of_connectors orelse 1)) * 100.0,
            n_connector_textures_created,
            self.number_of_connectors orelse 0,
        });
        printFn(" {d} modules", .{self.number_of_modules orelse 0});
        printFn(" {d} nodes", .{self.number_of_nodes orelse 0});
        printFn(" {d} connectors", .{self.number_of_connectors orelse 0});
    }
};
