//! Host-side editing session: owns the pipeline, the default raw -> display
//! graph, the image catalog behind the lighttable, and the UI model the plugin
//! draws. Anything the plugin wants done arrives as an `abi.Intent` and is
//! applied here, outside the render pass.

const std = @import("std");
const sokol = @import("sokol");
const sapp = sokol.app;
const pie = @import("pie");

const abi = @import("abi");
const Blit = @import("blit.zig").Blit;
const Catalog = @import("catalog.zig").Catalog;

const slog = std.log.scoped(.session);

pub const input_filename = "testing/images/DSC_6765.NEF";

pub const Session = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    gpu: *pie.GPU,

    pipeline: pie.Pipeline,
    blit: Blit,

    /// images the lighttable can open (scanned + thumbnailed by a worker)
    catalog: *Catalog,

    built: bool = false,
    model_built: bool = false,

    /// module handle per model index, for applying plugin edits
    handles: [model_module_capacity]pie.pipeline.ModuleHandle = @splat(undefined),
    module_count: usize = 0,

    /// Storage the `abi.Model` slices point into. It lives in `AppState`, which
    /// is never copied, so those pointers stay valid for the process.
    modules: [model_module_capacity]abi.ModuleView = @splat(.{}),
    params: [model_module_capacity][model_param_capacity]abi.ParamView = @splat(@splat(.{})),
    items: [model_item_capacity]abi.CatalogItem = @splat(.{}),

    /// catalog revision the lighttable model was built from
    model_catalog_revision: u32 = 0,

    /// Capacities of the editor model. Host-side only: the ABI carries slices,
    /// so the limits are an implementation detail here rather than part of the
    /// contract.
    const model_module_capacity = 32;
    const model_param_capacity = pie.api.MAX_PARAMS_PER_MODULE;
    const model_item_capacity = 256;

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, io: std.Io, gpu: *pie.GPU) !Self {
        var pipeline = try pie.Pipeline.init(allocator, io, gpu, null);
        errdefer pipeline.deinit();

        // the lighttable lists the directory the default image lives in
        const dir = std.fs.path.dirname(input_filename) orelse ".";
        const catalog = try Catalog.init(allocator, io, dir);
        errdefer catalog.deinit();

        return .{
            .allocator = allocator,
            .io = io,
            .gpu = gpu,
            .pipeline = pipeline,
            .blit = Blit.init(),
            .catalog = catalog,
        };
    }

    pub fn deinit(self: *Self) void {
        self.blit.deinit();
        self.catalog.deinit();
        self.pipeline.deinit();
    }

    /// Per-frame host work for the catalog: upload whatever the worker decoded.
    pub fn tick(self: *Self) void {
        self.catalog.tick();
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

    /// Publish what the editor draws. The model holds pointers into the live
    /// pipeline and the catalog, so this only rebuilds when one of them changed.
    pub fn refreshModel(self: *Self, model: *abi.Model) void {
        if (!self.built) return;
        if (self.model_built and self.model_catalog_revision == self.catalog.revision) return;

        self.rebuildDarkroom(model);
        self.rebuildLighttable(model);

        self.model_built = true;
        self.model_catalog_revision = self.catalog.revision;
    }

    /// Drain the intents the plugin queued this frame. Returns true when the
    /// pipeline needs re-running.
    pub fn applyIntents(self: *Self, state: *abi.SharedState) bool {
        const count = @min(state.intent_count, abi.max_intents);
        const intents = state.intents[0..count];
        state.intent_count = 0;

        var rerun = false;
        for (intents) |intent| {
            switch (intent) {
                .none => {},
                .set_param => |edit| {
                    rerun = self.writeParam(edit.module, edit.param, edit.value) or rerun;
                },
                .switch_view => |view| {
                    slog.info("switching to {s}", .{@tagName(view)});
                    state.view = view;
                },
                .open_image => |index| {
                    if (self.openImage(state, index)) rerun = true;
                },
                .reload_catalog => {
                    slog.info("reloading the catalog", .{});
                    self.catalog.reload();
                },
                .quit => {
                    slog.info("quit requested", .{});
                    sapp.requestQuit();
                },
            }
        }
        return rerun;
    }

    /// Load a catalog entry into the graph's source module and show the darkroom.
    fn openImage(self: *Self, state: *abi.SharedState, index: u32) bool {
        if (index >= self.catalog.entries.len) return false;
        const path = self.catalog.entries[index].path;

        self.setSourcePath(path) catch |err| {
            slog.err("cannot open '{s}': {s}", .{ path, @errorName(err) });
            return false;
        };
        slog.info("opening '{s}'", .{path});
        state.view = .darkroom;
        return true;
    }

    /// Point the graph's source module at `path`. The source is found by name
    /// (`filename`, a string param) rather than by module type, so it keeps
    /// working when the input module changes.
    fn setSourcePath(self: *Self, path: []const u8) !void {
        var handles = self.pipeline.module_pool.liveHandles();
        while (handles.next()) |handle| {
            const mod = self.pipeline.module_pool.getPtr(handle) catch continue;
            const param_index = mod.getParamIndex("filename") catch continue;
            const param = mod.params[param_index] orelse continue;
            if (param.desc.typ != .str) continue;
            try self.pipeline.setModuleParam(handle, "filename", []const u8, path);
            return;
        }
        return error.NoSourceModule;
    }

    /// Resolve `set_param`'s addressing (model index -> module handle -> param
    /// name) and write the value.
    fn writeParam(self: *Self, module_index: u32, param_index: u32, value: abi.ParamValue) bool {
        if (module_index >= self.module_count) return false;
        const handle = self.handles[module_index];
        const mod = self.pipeline.module_pool.getPtr(handle) catch return false;
        if (param_index >= mod.params.len) return false;
        const param = if (mod.params[param_index]) |*p| p else return false;
        const name = param.desc.name;

        const ok = switch (value) {
            .scalar => |v| self.pipeline.setModuleParam(handle, name, f32, v),
            .integer => |v| self.pipeline.setModuleParam(handle, name, i32, v),
            .vector => |vec| switch (vec.count) {
                2 => self.pipeline.setModuleParam(handle, name, [2]f32, vec.values[0..2].*),
                3 => self.pipeline.setModuleParam(handle, name, [3]f32, vec.values[0..3].*),
                4 => self.pipeline.setModuleParam(handle, name, [4]f32, vec.values[0..4].*),
                else => return false,
            },
            .text => |t| self.pipeline.setModuleParam(handle, name, []const u8, t.slice()),
        };

        ok catch |err| {
            slog.warn("set_param '{s}' failed: {s}", .{ name, @errorName(err) });
            return false;
        };
        return true;
    }

    fn rebuildDarkroom(self: *Self, model: *abi.Model) void {
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

        model.darkroom.modules = self.modules[0..self.module_count];
    }

    fn rebuildLighttable(self: *Self, model: *abi.Model) void {
        const entries = self.catalog.entries;
        const count = @min(entries.len, self.items.len);
        if (entries.len > self.items.len) {
            slog.warn("catalog has {d} images, the lighttable shows the first {d}", .{ entries.len, self.items.len });
        }

        for (entries[0..count], 0..) |entry, index| {
            const state = self.catalog.entryState(index);
            const size = self.catalog.thumbSize(index);
            self.items[index] = .{
                .name = entry.name,
                .thumb = if (state.ready) .{
                    .id = self.catalog.textureOf(index),
                    .width = @floatFromInt(size[0]),
                    .height = @floatFromInt(size[1]),
                } else null,
                .failed = state.failed,
            };
        }

        model.lighttable = .{
            .dir = self.catalog.dir,
            .items = self.items[0..count],
        };
    }

    // ------------------------------------------------------------------
    // the default graph
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
        // from 1/(srgb_from_xyz*xyz_d65_from_cam*(1/wb_cam)) of DSC_6765.NEF
        try pipeline.setModuleParam(mod_color, "wb_coeff", [3]f32, .{ 0.70393723, 1, 1.3611937 });
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
