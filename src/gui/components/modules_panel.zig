//! The pipeline modules as CUI cards: one accordion per module, with the
//! engine's own parameter descriptors driving the controls.

const std = @import("std");
const cui = @import("cui");
const session = @import("session");
const pie = @import("pie");
const ui = @import("types").ui;
const util = @import("../cui_util.zig");

const max_str_bytes = 256;

pub const ModulesPanel = struct {
    allocator: std.mem.Allocator,
    open: std.AutoHashMapUnmanaged(u64, bool) = .empty,
    strings: util.FrameStrings,

    /// CUI's text field keeps a pointer to the edit buffer in its state, so a
    /// string parameter needs a stable buffer that outlives the call.
    text_buffers: std.AutoHashMapUnmanaged(TextKey, *TextState) = .empty,

    const TextKey = struct {
        module: u64,
        index: u16,
    };

    const TextState = struct {
        buf: [max_str_bytes]u8 = @splat(0),
        focused: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator) !ModulesPanel {
        return .{
            .allocator = allocator,
            .strings = util.FrameStrings.init(allocator),
        };
    }

    pub fn deinit(self: *ModulesPanel) void {
        var it = self.text_buffers.valueIterator();
        while (it.next()) |state| self.allocator.destroy(state.*);
        self.text_buffers.deinit(self.allocator);
        self.open.deinit(self.allocator);
        self.strings.deinit();
    }

    pub fn draw(self: *ModulesPanel, s: *session.Session, cui_ui: *cui.cui_ctx) void {
        self.strings.reset();

        var panel = util.zero(cui.cui_box);
        panel.dir = @intCast(cui.CUI_COLUMN);
        panel.width = util.fill();
        panel.height = util.fill();
        panel.bg = util.token(cui_ui, cui.CUI_TOKEN_BACKGROUND);
        panel.pad = 6;
        panel.gap = 6;
        _ = cui.cui_column_begin(cui_ui, &panel);
        defer cui.cui_box_end(cui_ui);

        cui.cui_label(cui_ui, "Pipeline modules");

        var scroll = util.zero(cui.cui_scroll_opts);
        scroll.id = "module-scroll";
        scroll.width = util.fill();
        scroll.height = util.fill();
        scroll.gap = 6;
        cui.cui_scroll_begin(cui_ui, &scroll);
        defer cui.cui_scroll_end(cui_ui);

        var index: usize = 0;
        var it = s.pipeline.module_pool.liveHandles();
        while (it.next()) |handle| {
            const mod = s.pipeline.module_pool.getPtr(handle) catch continue;
            self.drawModule(s, cui_ui, handle, mod, index);
            index += 1;
        }
    }

    fn drawModule(
        self: *ModulesPanel,
        s: *session.Session,
        cui_ui: *cui.cui_ctx,
        handle: pie.pipeline.ModuleHandle,
        mod: *pie.api.Module,
        module_index: usize,
    ) void {
        const gop = self.open.getOrPut(self.allocator, handle.id) catch return;
        if (!gop.found_existing) gop.value_ptr.* = true;

        const title = self.strings.fmt("{s}:{s}", .{ mod.name, mod.id }) catch return;

        if (cui.cui_accordion_begin(cui_ui, title.ptr, gop.value_ptr)) {
            defer cui.cui_accordion_end(cui_ui);

            var id_buf: [48]u8 = undefined;
            cui.cui_push_id(cui_ui, util.z(&id_buf, "{d}", .{module_index}));
            defer cui.cui_pop_id(cui_ui);

            var body = util.zero(cui.cui_box);
            body.dir = @intCast(cui.CUI_COLUMN);
            body.width = util.fill();
            body.gap = 6;
            body.pad_y = 3;
            _ = cui.cui_column_begin(cui_ui, &body);
            defer cui.cui_box_end(cui_ui);

            for (mod.params_ui, 0..) |maybe_ui, param_index| {
                const control = maybe_ui orelse continue;
                const idx = mod.getParamIndex(control.name) catch continue;
                const param = mod.params[idx] orelse continue;
                self.drawParam(s, cui_ui, handle, &param, control.control, @intCast(param_index));
            }
        }
    }

    fn drawParam(
        self: *ModulesPanel,
        s: *session.Session,
        cui_ui: *cui.cui_ctx,
        handle: pie.pipeline.ModuleHandle,
        param: *const pie.api.Param,
        control: ui.Control,
        param_index: u32,
    ) void {
        cui.cui_push_id_int(cui_ui, @intCast(param_index));
        defer cui.cui_pop_id(cui_ui);

        switch (control) {
            .slider => |slider| self.drawSlider(s, cui_ui, handle, param, slider),
            .sliders => |sliders| self.drawSliders(s, cui_ui, handle, param, sliders),
            .combo => |combo| self.drawCombo(s, cui_ui, handle, param, combo),
            .checkbox => self.drawCheckbox(s, cui_ui, handle, param),
            .text => self.drawText(s, cui_ui, handle, param, @intCast(param_index)),
            .readonly => self.drawReadonly(cui_ui, param),
        }
    }

    fn drawSlider(
        self: *ModulesPanel,
        s: *session.Session,
        cui_ui: *cui.cui_ctx,
        handle: pie.pipeline.ModuleHandle,
        param: *const pie.api.Param,
        slider: ui.Slider,
    ) void {
        const label = self.strings.fmt("{s}", .{param.desc.name}) catch return;
        const suffix = slider.suffix orelse "";

        var opts = util.zero(cui.cui_scrub_opts);
        opts.format = "%.2f";
        if (suffix.len > 0) opts.suffix = (self.strings.alloc(suffix) catch return).ptr;

        switch (param.desc.typ) {
            .f32 => {
                var value = read(param, f32, 0);
                if (cui.cui_scrub_ex(cui_ui, label.ptr, &value, slider.min, slider.max, &opts)) {
                    s.setParam(handle, param.desc.name, f32, value);
                }
            },
            .i32 => {
                var value: f32 = @floatFromInt(read(param, i32, 0));
                var iopts = util.zero(cui.cui_scrub_opts);
                iopts.step = 1;
                iopts.format = "%.0f";
                if (suffix.len > 0) iopts.suffix = (self.strings.alloc(suffix) catch return).ptr;
                if (cui.cui_scrub_ex(cui_ui, label.ptr, &value, @floor(slider.min), @ceil(slider.max), &iopts)) {
                    s.setParam(handle, param.desc.name, i32, @intFromFloat(@round(value)));
                }
            },
            else => {},
        }
    }

    fn drawSliders(
        self: *ModulesPanel,
        s: *session.Session,
        cui_ui: *cui.cui_ctx,
        handle: pie.pipeline.ModuleHandle,
        param: *const pie.api.Param,
        sliders: ui.Sliders,
    ) void {
        if (param.desc.typ != .f32) return;
        const n = @min(sliders.n, @as(usize, param.desc.len));
        if (n == 0 or n > 4) return;

        const param_name = self.strings.fmt("{s}", .{param.desc.name}) catch return;
        cui.cui_secondary(cui_ui, param_name.ptr);

        var values: [4]f32 = @splat(0);
        for (0..n) |i| values[i] = read(param, f32, i);

        var changed = false;
        for (0..n) |i| {
            const suffix = if (sliders.suffixes) |suffixes| if (i < suffixes.len) suffixes[i] else "" else "";
            const elem = if (sliders.labels) |labels| if (i < labels.len) labels[i] else "" else "";
            const label = if (elem.len > 0)
                self.strings.fmt("{s}", .{elem}) catch continue
            else
                self.strings.fmt("[{d}]", .{i}) catch continue;

            var opts = util.zero(cui.cui_scrub_opts);
            opts.format = "%.3f";
            if (suffix.len > 0) opts.suffix = (self.strings.alloc(suffix) catch continue).ptr;
            if (cui.cui_scrub_ex(cui_ui, label.ptr, &values[i], sliders.min, sliders.max, &opts)) changed = true;
        }

        if (changed) {
            switch (n) {
                2 => s.setParam(handle, param.desc.name, [2]f32, values[0..2].*),
                3 => s.setParam(handle, param.desc.name, [3]f32, values[0..3].*),
                4 => s.setParam(handle, param.desc.name, [4]f32, values[0..4].*),
                else => {},
            }
        }
    }

    fn drawCombo(
        self: *ModulesPanel,
        s: *session.Session,
        cui_ui: *cui.cui_ctx,
        handle: pie.pipeline.ModuleHandle,
        param: *const pie.api.Param,
        combo: ui.Combo,
    ) void {
        if (combo.items.len == 0) return;

        const label = self.strings.fmt("{s}", .{param.desc.name}) catch return;

        const count = @min(combo.items.len, 32);
        const items = self.strings.arena.allocator().alloc([*c]const u8, count) catch return;
        for (combo.items[0..count], 0..) |item, i| items[i] = @ptrCast(item.ptr);

        var current: c_int = switch (param.desc.typ) {
            .i32 => read(param, i32, 0),
            .enum_u32 => @intCast(read(param, u32, 0)),
            else => 0,
        };
        var opts = util.zero(cui.cui_select_opts);
        opts.label = label.ptr;
        if (cui.cui_select_ex(cui_ui, label.ptr, @ptrCast(items.ptr), @intCast(count), &current, &opts)) {
            s.setParam(handle, param.desc.name, u32, @intCast(current));
        }
    }

    fn drawCheckbox(
        self: *ModulesPanel,
        s: *session.Session,
        cui_ui: *cui.cui_ctx,
        handle: pie.pipeline.ModuleHandle,
        param: *const pie.api.Param,
    ) void {
        const label = self.strings.fmt("{s}", .{param.desc.name}) catch return;
        var value = read(param, i32, 0) != 0;
        var opts = util.zero(cui.cui_check_opts);
        if (cui.cui_checkbox_ex(cui_ui, label.ptr, &value, &opts)) {
            s.setParam(handle, param.desc.name, i32, if (value) 1 else 0);
        }
    }

    fn drawText(
        self: *ModulesPanel,
        s: *session.Session,
        cui_ui: *cui.cui_ctx,
        handle: pie.pipeline.ModuleHandle,
        param: *const pie.api.Param,
        param_index: u16,
    ) void {
        const label = self.strings.fmt("{s}", .{param.desc.name}) catch return;

        const gop = self.text_buffers.getOrPut(self.allocator, .{
            .module = handle.id,
            .index = param_index,
        }) catch return;
        if (!gop.found_existing) {
            const state = self.allocator.create(TextState) catch return;
            state.* = .{};
            gop.value_ptr.* = state;
        }
        const state = gop.value_ptr.*;

        // While not editing, follow the engine value (it can change from the
        // graph, presets, or opening another image).
        if (!state.focused) {
            const current = readStr(param);
            const n = @min(current.len, state.buf.len - 1);
            @memset(&state.buf, 0);
            @memcpy(state.buf[0..n], current[0..n]);
        }

        var opts = util.zero(cui.cui_input_opts);
        opts.label = label.ptr;
        const flags = cui.cui_input_ex(cui_ui, label.ptr, @ptrCast(&state.buf), state.buf.len, &opts);
        if ((flags & cui.CUI_FOCUSED) != 0) state.focused = true;
        if ((flags & cui.CUI_BLURRED) != 0) state.focused = false;
        if ((flags & cui.CUI_CHANGED) != 0) {
            s.setParam(handle, param.desc.name, []const u8, std.mem.sliceTo(&state.buf, 0));
        }
    }

    fn drawReadonly(self: *ModulesPanel, cui_ui: *cui.cui_ctx, param: *const pie.api.Param) void {
        const name = param.desc.name;
        const text = switch (param.desc.typ) {
            .f32 => self.strings.fmt("{s}: {d:.2}", .{ name, read(param, f32, 0) }) catch return,
            .i32 => self.strings.fmt("{s}: {d}", .{ name, read(param, i32, 0) }) catch return,
            .str => self.strings.fmt("{s}: {s}", .{ name, readStr(param) }) catch return,
            .enum_u32 => self.strings.fmt("{s}: {d}", .{ name, read(param, u32, 0) }) catch return,
        };
        cui.cui_muted(cui_ui, text.ptr);
    }

    fn read(param: *const pie.api.Param, T: type, index: usize) T {
        const offset = index * @sizeOf(T);
        if (offset + @sizeOf(T) > param.bytes.len) return undefined;
        return std.mem.bytesToValue(T, param.bytes[offset..][0..@sizeOf(T)]);
    }

    fn readStr(param: *const pie.api.Param) []const u8 {
        return std.mem.sliceTo(param.bytes, 0);
    }
};
