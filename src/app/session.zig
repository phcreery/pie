//! Host-side editing session: owns the pipeline, the default raw -> display
//! graph, the UI model the plugin draws, and the parameter edits it returns.
//!
//! This used to live in the plugin (`views/darkroom.zig` + `components/image.zig`).
//! Keeping it in the host is what makes the plugin thin: the plugin no longer
//! reaches into the engine, so it compiles in about a second and a reload keeps
//! the pipeline, textures and view state without any hand-off.

const std = @import("std");
const pie = @import("pie");

const abi = @import("abi");
const Blit = @import("blit.zig").Blit;

const slog = std.log.scoped(.session);

pub const input_filename = "testing/images/DSC_6765.NEF";

pub const Session = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    gpu: *pie.GPU,

    pipeline: pie.Pipeline,
    blit: Blit,

    built: bool = false,

    /// module handle per model index, for applying plugin edits
    handles: [model_module_capacity]pie.pipeline.ModuleHandle = @splat(undefined),
    module_count: usize = 0,

    /// Storage the `abi.Model` slices point into. It lives in `AppState`, which
    /// is never copied, so those pointers stay valid for the process.
    modules: [model_module_capacity]abi.ModuleView = @splat(.{}),
    params: [model_module_capacity][model_param_capacity]abi.ParamView = @splat(@splat(.{})),

    /// Capacities of the editor model. Host-side only: the ABI carries slices,
    /// so the limits are an implementation detail here rather than part of the
    /// contract.
    const model_module_capacity = 32;
    const model_param_capacity = pie.api.MAX_PARAMS_PER_MODULE;

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, io: std.Io, gpu: *pie.GPU) !Self {
        return .{
            .allocator = allocator,
            .io = io,
            .gpu = gpu,
            .pipeline = try pie.Pipeline.init(allocator, io, gpu, null),
            .blit = Blit.init(),
        };
    }

    pub fn deinit(self: *Self) void {
        self.blit.deinit();
        self.pipeline.deinit();
    }

    /// Build and run the default graph on the first frame. Errors are reported
    /// and retried on the next frame rather than taking the app down. Returns
    /// true once the session is usable.
    pub fn ensureBuilt(self: *Self) bool {
        if (self.built) return true;
        self.buildDefaultGraph() catch |err| {
            slog.err("could not build the default pipeline: {s}", .{@errorName(err)});
            return false;
        };
        self.run() catch |err| {
            slog.err("could not run the default pipeline: {s}", .{@errorName(err)});
            return false;
        };
        self.built = true;
        return true;
    }

    /// Re-run the pipeline and publish the (possibly new) display texture.
    pub fn run(self: *Self) !void {
        try self.pipeline.run();
        const texture = try self.pipeline.getDisplaySinkTexture();
        self.blit.setTexture(texture);
    }

    /// Apply the edits the plugin queued this frame. Returns true when the
    /// pipeline needs re-running.
    pub fn applyEdits(self: *Self, state: *abi.SharedState) bool {
        const count = @min(state.edit_count, abi.max_edits);
        const edits = state.edits[0..count];
        state.edit_count = 0;

        var applied = false;
        for (edits) |edit| {
            // Resolve the target: model index -> module handle -> param name.
            if (edit.module >= self.module_count) continue;
            const handle = self.handles[edit.module];
            const mod = self.pipeline.module_pool.getPtr(handle) catch continue;
            if (edit.param >= mod.params.len) continue;
            const param = if (mod.params[edit.param]) |*p| p else continue;
            const name = param.desc.name;

            applied = switch (edit.value) {
                .scalar => |v| self.setParam(handle, name, f32, v),
                .integer => |v| self.setParam(handle, name, i32, v),
                .vector => |vec| switch (vec.count) {
                    2 => self.setParam(handle, name, [2]f32, vec.values[0..2].*),
                    3 => self.setParam(handle, name, [3]f32, vec.values[0..3].*),
                    4 => self.setParam(handle, name, [4]f32, vec.values[0..4].*),
                    else => false,
                },
                .text => |t| self.setParam(handle, name, []const u8, t.slice()),
            } or applied;
        }
        return applied;
    }

    fn setParam(self: *Self, handle: pie.pipeline.ModuleHandle, name: []const u8, comptime T: type, value: T) bool {
        self.pipeline.setModuleParam(handle, name, T, value) catch |err| {
            slog.warn("edit of '{s}' failed: {s}", .{ name, @errorName(err) });
            return false;
        };
        return true;
    }

    /// Publish what the editor draws. The model holds pointers into the live
    /// pipeline, so it only needs rebuilding when the graph changes.
    pub fn rebuildModel(self: *Self, model: *abi.Model) void {
        self.module_count = 0;
        self.handles = @splat(undefined);

        var handles = self.pipeline.module_pool.liveHandles();
        while (handles.next()) |handle| {
            if (self.module_count >= self.modules.len) {
                slog.warn("pipeline has more than {d} modules, the editor shows the first {d}", .{
                    self.modules.len, self.modules.len,
                });
                break;
            }
            const mod = self.pipeline.module_pool.getPtr(handle) catch continue;

            const index = self.module_count;
            self.handles[index] = handle;

            var param_count: usize = 0;
            for (mod.params_ui) |maybe_ui| {
                const param_ui = maybe_ui orelse continue;
                // Match by name, not position: a module may expose only the
                // params it wants, in any order (e.g. `color` exposes
                // `wb_coeff`, which is its third param).
                const param_index = mod.getParamIndex(param_ui.name) catch continue;
                const param = if (mod.params[param_index]) |*p| p else continue;
                if (param_count == self.params[index].len) break;

                if (std.meta.activeTag(param_ui.control) == .sliders) {
                    const sliders = param_ui.control.sliders;
                    if (sliders.n != @as(usize, param.desc.len)) {
                        slog.warn("module '{s}': params_ui for '{s}' declares sliders.n={d} but the param len is {d}", .{
                            mod.name, param.desc.name, sliders.n, param.desc.len,
                        });
                    }
                }

                // The params_ui hint and the param's descriptor are shared
                // types, so this is a straight hand-over, not a translation.
                self.params[index][param_count] = .{
                    .param_index = @intCast(param_index),
                    .desc = param.desc,
                    .control = param_ui.control,
                    .value = param.bytes,
                };
                param_count += 1;
            }

            self.modules[index] = .{
                .name = mod.name,
                .params = self.params[index][0..param_count],
            };
            self.module_count += 1;
        }

        model.modules = self.modules[0..self.module_count];
    }

    // ------------------------------------------------------------------
    // the default graph (was `build_image` in the GUI plugin)
    // ------------------------------------------------------------------
    fn buildDefaultGraph(self: *Self) !void {
        const pipeline = &self.pipeline;

        const mod_i_raw = try pipeline.addModule("01", "i-raw");
        const mod_format = try pipeline.addModule("01", "format");
        const mod_denoise = try pipeline.addModule("01", "denoise");
        const mod_demosaic = try pipeline.addModule("01", "demosaic");
        const mod_crop = try pipeline.addModule("01", "crop");
        const mod_color = try pipeline.addModule("01", "color");
        const mod_filmcurv = try pipeline.addModule("01", "filmcurv");
        const mod_o_display = try pipeline.addModule("01", "o-display");

        try pipeline.setModuleParam(mod_i_raw, "filename", []const u8, input_filename);
        try pipeline.setModuleParam(mod_i_raw, "wb_mode", i32, 0);
        try pipeline.setModuleParam(mod_color, "wb_tint", f32, 0.0);
        try pipeline.setModuleParam(mod_color, "wb_coeff", [3]f32, .{ 0.70393723, 1, 1.3611937 }); // from 1/(srgb_from_xyz*xyz_d65_from_cam*(1/wb_cam)) of DSC_6765.NEF
        try pipeline.setModuleParam(mod_filmcurv, "colormode", i32, 1);
        try pipeline.setModuleParam(mod_filmcurv, "brightness", f32, 3.8);
        try pipeline.setModuleParam(mod_filmcurv, "contrast", f32, 1.3);
        try pipeline.setModuleParam(mod_filmcurv, "bias", f32, 0.0);

        try pipeline.connectModules(mod_i_raw, "output", mod_format, "input");
        try pipeline.connectModules(mod_format, "output", mod_denoise, "input");
        try pipeline.connectModules(mod_denoise, "output", mod_demosaic, "input");
        try pipeline.connectModules(mod_demosaic, "output", mod_crop, "input");
        try pipeline.connectModules(mod_crop, "output", mod_color, "input");
        try pipeline.connectModules(mod_color, "output", mod_filmcurv, "input");
        try pipeline.connectModules(mod_filmcurv, "output", mod_o_display, "input");
    }
};
