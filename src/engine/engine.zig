const std = @import("std");
const wgpu = @import("wgpu");

const Engine = struct {
    instance: *wgpu.Instance = undefined,
    adapter: *wgpu.Adapter = undefined,
    device: *wgpu.Device = undefined,
    queue: *wgpu.Queue = undefined,

    const Self = @This();

    pub fn init() Self {
        std.log.info("Initializing Engine", .{});

        const instance = wgpu.Instance.create(null).?;
        errdefer instance.release();

        const adapter_request = instance.requestAdapterSync(&wgpu.RequestAdapterOptions{}, 0);
        const adapter = switch (adapter_request.status) {
            .success => adapter_request.adapter.?,
            else => return error.NoAdapter,
        };
        errdefer adapter.release();

        // We then create a `Device` and a `Queue` from the `Adapter`.
        const device_request = adapter.requestDeviceSync(instance, &wgpu.DeviceDescriptor{
            .required_limits = null,
        }, 0);
        const device = switch (device_request.status) {
            .success => device_request.device.?,
            else => return error.NoDevice,
        };
        defer device.release();

        const queue = device.getQueue().?;
        defer queue.release();

        return Self{
            .instance = instance,
            .adapter = adapter,
            .device = device,
            .queue = queue,
        };
    }

    pub fn deinit(self: *Self) void {
        std.log.info("Deinitializing Engine", .{});

        self.instance.release();
        self.adapter.release();
        self.device.release();
        self.queue.release();
    }
};
