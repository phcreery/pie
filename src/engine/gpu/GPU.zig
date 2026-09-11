//! GPU manages the WebGPU instance, adapter, device, and queue.
const std = @import("std");
const wgpu = @import("wgpu_zig");
const Shader = @import("Shader.zig");
const ShaderSource = Shader.ShaderSource;
const ShaderMap = Shader.ShaderMap;

const c = wgpu.c;
const slog = std.log.scoped(.gpu);

instance: ?wgpu.Instance,
adapter: ?wgpu.Adapter,
device: wgpu.Device,
queue: wgpu.Queue,
adapter_name: []const u8,
shader_cache: ShaderMap,

const Self = @This();

pub fn adapterLimits(self: *const Self) ?c.WGPULimits {
    const adapter = self.adapter orelse return null;
    return adapter.getLimits() catch null;
}

pub fn init(allocator: std.mem.Allocator, io: std.Io) !Self {
    _ = io; // not needed by wgpu-native (its futures resolve via device poll / process events)
    // _ = allocator;
    slog.debug("Initializing GPU", .{});

    const instance = try wgpu.Instance.init(null);
    errdefer instance.deinit();

    const adapter = try instance.requestAdapterSync(.{
        .power_preference = .high_performance,
    });
    errdefer adapter.deinit();

    const info = adapter.getInfo() catch {
        slog.err("Failed to get adapter info", .{});
        return error.AdapterInfo;
    };
    slog.info("Using adapter: {s} (backend={s}, type={s})", .{ info.device, @tagName(info.backend_type), @tagName(info.adapter_type) });

    // We then create a `Device` and a `Queue` from the `Adapter`.
    // https://webgpureport.org/
    //
    // The wgpu-zig Device.Descriptor does not (yet) expose required
    // features/limits, so request the device through the C API directly
    // and wrap the handle.
    const required_features = [_]c.WGPUFeatureName{
        c.WGPUFeatureName_ShaderF16, // enable f16 support
        // without this flag, read/write storage access is not allowed at all
        @as(c.WGPUFeatureName, @intCast(c.WGPUNativeFeature_TextureAdapterSpecificFormatFeatures)),
        // .mappable_primary_buffers, // https://docs.rs/wgpu-types/0.7.0/wgpu_types/struct.Features.html#associatedconstant.MAPPABLE_PRIMARY_BUFFERS
    };

    var required_limits = try adapter.getLimits();
    required_limits.maxStorageBufferBindingSize = 1024 * 1024 * 1024; // 1 GB
    required_limits.maxBufferSize = 1024 * 1024 * 1024; // 1 GB

    var device_data = DeviceRequestData{};
    const device_descriptor = c.WGPUDeviceDescriptor{
        .label = stringView("Device"),
        .requiredFeatureCount = required_features.len,
        .requiredFeatures = &required_features,
        .requiredLimits = &required_limits,
        .defaultQueue = .{
            .label = stringView("Queue"),
        },
        .deviceLostCallbackInfo = .{
            .mode = c.WGPUCallbackMode_AllowSpontaneous,
            .callback = deviceLostCb,
        },
        .uncapturedErrorCallbackInfo = .{
            .callback = uncapturedErrorCb,
        },
    };
    _ = c.wgpuAdapterRequestDevice(adapter.adapter, &device_descriptor, .{
        .mode = c.WGPUCallbackMode_AllowSpontaneous,
        .callback = requestDeviceCb,
        .userdata1 = &device_data,
    });
    while (device_data.device == null) {
        c.wgpuInstanceProcessEvents(instance.instance);
    }
    const device = wgpu.Device{
        .device = device_data.device orelse return error.NoDevice,
    };
    errdefer device.deinit();

    const queue = try device.getQueue();
    errdefer queue.deinit();

    const limits = try adapter.getLimits();

    slog.info("Adapter limits:", .{});
    slog.info("- max_bind_groups: {d}", .{limits.maxBindGroups});
    slog.info("- max_bindings_per_bind_group: {d}", .{limits.maxBindingsPerBindGroup});
    slog.info("- max_texture_dimension_2d: {d}", .{limits.maxTextureDimension2D});
    slog.info("- max_compute_invocations_per_workgroup: {d}", .{limits.maxComputeInvocationsPerWorkgroup});
    slog.info("- max_compute_workgroup_size_x: {d}", .{limits.maxComputeWorkgroupSizeX});
    slog.info("- max_compute_workgroup_size_y: {d}", .{limits.maxComputeWorkgroupSizeY});
    slog.info("- max_compute_workgroup_size_z: {d}", .{limits.maxComputeWorkgroupSizeZ});
    slog.info("- max_compute_workgroups_per_dimension: {d}", .{limits.maxComputeWorkgroupsPerDimension});
    slog.info("- max_buffer_size: {B:.2}", .{limits.maxBufferSize});
    slog.info("- max_uniform_buffer_binding_size: {B:.2}", .{limits.maxUniformBufferBindingSize});
    slog.info("- max_storage_buffer_binding_size: {B:.2}", .{limits.maxStorageBufferBindingSize});
    slog.info("- min_uniform_buffer_offset_alignment: {d}", .{limits.minUniformBufferOffsetAlignment});
    slog.info("- min_storage_buffer_offset_alignment: {d}", .{limits.minStorageBufferOffsetAlignment});

    const shader_cache = ShaderMap.init(allocator);

    return Self{
        .instance = instance,
        .adapter = adapter,
        .device = device,
        .queue = queue,
        .adapter_name = info.device,
        .shader_cache = shader_cache,
    };
}

pub fn initExternal(allocator: std.mem.Allocator, io: std.Io, device: wgpu.Device, queue: wgpu.Queue) !Self {
    _ = io;
    slog.debug("Initializing GPU from external sokol-owned WebGPU device/queue", .{});
    c.wgpuDeviceAddRef(device.device);
    errdefer device.deinit();
    c.wgpuQueueAddRef(queue.queue);
    errdefer queue.deinit();
    const shader_cache = ShaderMap.init(allocator);
    return .{
        .instance = null,
        .adapter = null,
        .device = device,
        .queue = queue,
        .adapter_name = "sokol-external-device",
        .shader_cache = shader_cache,
    };
}

pub fn deinit(self: *Self) void {
    slog.debug("De-initializing GPU", .{});

    self.queue.deinit();
    self.device.deinit();
    if (self.adapter) |adapter| adapter.deinit();
    if (self.instance) |instance| instance.deinit();
    self.shader_cache.deinit();
}

pub fn compileShader(self: *Self, shader_source: ShaderSource) !Shader {
    const shader = self.shader_cache.get(shader_source) orelse blk: {
        slog.info("Shader not found in cache, compiling new shader", .{});
        const shader = try Shader.compile(self, shader_source);
        self.shader_cache.put(shader_source, shader) catch {
            slog.err("Failed to cache shader", .{});
        };
        break :blk shader;
    };
    return shader;
}

pub fn run(self: *Self, command_buffer: ?wgpu.CommandEncoder.CommandBuffer) !void {
    slog.debug("Submitting command buffer to GPU", .{});

    const command_buffer_unwrapped = command_buffer orelse {
        slog.err("No command buffer provided to GPU.run", .{});
        return error.InvalidCommandBuffer;
    };

    // At this point nothing has actually been executed on the gpu. We have recorded a series of
    // commands that we want to execute, but they haven't been sent to the gpu yet.
    //
    // Submitting to the queue sends the command buffer to the gpu. The gpu will then execute the
    // commands in the command buffer in order.
    // NOTE: Queue.submitCommands releases the command buffer for us.
    self.queue.submitCommands(&.{command_buffer_unwrapped});
}

// ================
// INTERNAL HELPERS
// ================

fn stringView(s: []const u8) c.WGPUStringView {
    return .{ .data = s.ptr, .length = s.len };
}

const DeviceRequestData = struct {
    device: c.WGPUDevice = null,
};

fn requestDeviceCb(
    status: c.WGPURequestDeviceStatus,
    device_handle: c.WGPUDevice,
    _: c.WGPUStringView,
    userdata1: ?*anyopaque,
    _: ?*anyopaque,
) callconv(.c) void {
    const data: *DeviceRequestData = @ptrCast(@alignCast(userdata1));
    if (status == c.WGPURequestDeviceStatus_Success) {
        data.device = device_handle;
    }
}

fn deviceLostCb(
    _: [*c]const c.WGPUDevice,
    reason: c.WGPUDeviceLostReason,
    message: c.WGPUStringView,
    _: ?*anyopaque,
    _: ?*anyopaque,
) callconv(.c) void {
    const msg = if (message.length > 0) message.data[0..message.length] else "";
    slog.err("Device lost (reason={d}): {s}", .{ reason, msg });
}

fn uncapturedErrorCb(
    _: [*c]const c.WGPUDevice,
    err_type: c.WGPUErrorType,
    message: c.WGPUStringView,
    _: ?*anyopaque,
    _: ?*anyopaque,
) callconv(.c) void {
    if (err_type == c.WGPUErrorType_NoError) return;
    const msg = if (message.length > 0) message.data[0..message.length] else "";
    slog.err("Uncaptured error (type={d}): {s}", .{ err_type, msg });
}
