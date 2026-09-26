//! Renders one collapsible section per module in the pipeline.
//!
//! Everything it draws comes from the host-built `abi.Model`: the parameter's
//! descriptor and UI hint are the engine's own `types/ui.zig` types (shared, not
//! mirrored), and its value is read through `ParamView.value` (live host memory).
//! Changes are queued as `abi.Edit` intents in `SharedState` for the host to
//! apply. No engine code reaches into this module, which is what keeps the
//! plugin small.

const std = @import("std");
const ig = @import("cimgui");
const abi = @import("abi");
const ui = @import("types").ui;

pub const ModulesPanel = struct {
    pub fn draw(state: *abi.SharedState, model: *const abi.Model) void {
        // no `MenuBar` flag: it reserves a menu-bar strip we never draw into,
        // which shows up as a blank band under the title bar.
        if (!ig.igBegin("Modules", &state.panel_open, ig.ImGuiWindowFlags_None)) {
            ig.igEnd();
            return;
        }
        defer ig.igEnd();

        ig.igText("pipeline modules");
        ig.igSeparator();

        for (model.modules, 0..) |*mod, module_index| {
            drawModule(state, mod, module_index);
        }
    }

    fn drawModule(state: *abi.SharedState, mod: *const abi.ModuleView, module_index: usize) void {
        ig.igPushIDInt(@intCast(module_index));
        defer ig.igPopID();

        var header_buf: [160]u8 = undefined;
        const header = std.mem.printSentinel(&header_buf, "{s}##{d}", .{ mod.name, module_index }, 0) catch return;

        const open = ig.igCollapsingHeader(
            header.ptr,
            ig.ImGuiTreeNodeFlags_OpenOnArrow | ig.ImGuiTreeNodeFlags_OpenOnDoubleClick | ig.ImGuiTreeNodeFlags_DefaultOpen,
        );
        if (!open) return;

        ig.igIndentEx(8.0);
        defer ig.igUnindentEx(8.0);

        for (mod.params) |*param| {
            drawParam(state, param, module_index);
        }
    }

    fn drawParam(state: *abi.SharedState, param: *const abi.ParamView, module_index: usize) void {
        switch (param.control) {
            .slider => |slider| drawSlider(state, param, slider, module_index),
            .sliders => |sliders| drawSliders(state, param, sliders, module_index),
            .combo => |combo| drawCombo(state, param, combo, module_index),
            .checkbox => drawCheckbox(state, param, module_index),
            .text => drawText(state, param, module_index),
            .readonly => drawReadonly(param),
        }
    }

    fn drawSlider(
        state: *abi.SharedState,
        param: *const abi.ParamView,
        slider: ui.Slider,
        module_index: usize,
    ) void {
        var label_buf: [160]u8 = undefined;
        const label = labelZ(&label_buf, param);
        ig.igPushIDInt(@intCast(param.param_index));
        defer ig.igPopID();

        const suffix = slider.suffix orelse "";
        switch (param.desc.typ) {
            .f32 => {
                var value = readF32(param, 0);
                var format_buf: [32]u8 = undefined;
                const format = std.mem.printSentinel(&format_buf, "%.2f{s}", .{suffix}, 0) catch "%.2f";
                if (ig.igSliderFloatEx(label.ptr, &value, slider.min, slider.max, format.ptr, 0)) {
                    _ = state.pushEdit(edit(module_index, param, .{ .scalar = value }));
                }
            },
            .i32 => {
                var value = readI32(param, 0);
                if (ig.igSliderInt(label.ptr, &value, @intFromFloat(@floor(slider.min)), @intFromFloat(@ceil(slider.max)))) {
                    _ = state.pushEdit(edit(module_index, param, .{ .integer = value }));
                }
            },
            .str => {},
        }
    }

    fn drawSliders(
        state: *abi.SharedState,
        param: *const abi.ParamView,
        sliders: ui.Sliders,
        module_index: usize,
    ) void {
        if (param.desc.typ != .f32) return; // only float arrays are supported for now

        // declared element count, bounded by the storage the param actually has
        const n = @min(sliders.n, @as(usize, param.desc.len));
        if (n == 0 or n > 4) return; // only 2/3/4-element vectors can be committed

        ig.igPushIDInt(@intCast(param.param_index));
        defer ig.igPopID();

        var name_buf: [160]u8 = undefined;
        const name = std.mem.printSentinel(&name_buf, "{s}", .{param.desc.name}, 0) catch return;
        ig.igText("%s", name.ptr);

        var values: [4]f32 = @splat(0);
        for (0..n) |i| values[i] = readF32(param, i);

        var changed = false;
        for (0..n) |i| {
            const suffix = if (sliders.suffixes) |suffixes| if (i < suffixes.len) suffixes[i] else "" else "";
            var format_buf: [32]u8 = undefined;
            const format = std.mem.printSentinel(&format_buf, "%.3f{s}", .{suffix}, 0) catch "%.3f";

            // per-element label if provided (e.g. "R", "G", "B"), else "[i]"
            const elem_label = if (sliders.labels) |labels| if (i < labels.len) labels[i] else "" else "";
            var id_buf: [64]u8 = undefined;
            const id = if (elem_label.len > 0)
                std.mem.printSentinel(&id_buf, "{s}##{d}", .{ elem_label, i }, 0) catch return
            else
                std.mem.printSentinel(&id_buf, "[{d}]##{d}", .{ i, i }, 0) catch return;

            if (ig.igSliderFloatEx(id.ptr, &values[i], sliders.min, sliders.max, format.ptr, 0)) changed = true;
        }

        if (changed) {
            var vector: abi.EditVector = .{ .count = @intCast(n) };
            @memcpy(vector.values[0..n], values[0..n]);
            _ = state.pushEdit(edit(module_index, param, .{ .vector = vector }));
        }
    }

    fn drawCombo(
        state: *abi.SharedState,
        param: *const abi.ParamView,
        combo: ui.Combo,
        module_index: usize,
    ) void {
        var label_buf: [160]u8 = undefined;
        const label = labelZ(&label_buf, param);

        // zero-separated items string, the form imgui wants ("a\x00b\x00\x00")
        var items_buf: [512]u8 = undefined;
        var pos: usize = 0;
        for (combo.items) |item| {
            if (pos + item.len + 1 > items_buf.len) break;
            @memcpy(items_buf[pos..][0..item.len], item);
            pos += item.len;
            items_buf[pos] = 0;
            pos += 1;
        }
        if (pos == 0) return;
        items_buf[pos] = 0;
        const items_z = items_buf[0 .. pos + 1];

        ig.igPushIDInt(@intCast(param.param_index));
        defer ig.igPopID();

        var current: c_int = if (param.desc.typ == .i32) readI32(param, 0) else 0;
        if (ig.igCombo(label.ptr, &current, @ptrCast(items_z.ptr))) {
            _ = state.pushEdit(edit(module_index, param, .{ .integer = current }));
        }
    }

    fn drawCheckbox(state: *abi.SharedState, param: *const abi.ParamView, module_index: usize) void {
        var label_buf: [160]u8 = undefined;
        const label = labelZ(&label_buf, param);
        var value = readI32(param, 0) != 0;
        if (ig.igCheckbox(label.ptr, &value)) {
            _ = state.pushEdit(edit(module_index, param, .{ .integer = if (value) 1 else 0 }));
        }
    }

    fn drawText(state: *abi.SharedState, param: *const abi.ParamView, module_index: usize) void {
        var label_buf: [160]u8 = undefined;
        const label = labelZ(&label_buf, param);

        var buf: [abi.max_str_bytes]u8 = @splat(0);
        const current = readStr(param);
        const n = @min(current.len, buf.len - 1);
        @memcpy(buf[0..n], current[0..n]);

        ig.igPushIDInt(@intCast(param.param_index));
        defer ig.igPopID();

        if (ig.igInputText(label.ptr, &buf, buf.len, ig.ImGuiInputTextFlags_None)) {
            const text = std.mem.sliceTo(&buf, 0);
            var payload: abi.EditText = .{ .len = @intCast(@min(text.len, abi.max_str_bytes)) };
            @memcpy(payload.bytes[0..payload.len], text[0..payload.len]);
            _ = state.pushEdit(edit(module_index, param, .{ .text = payload }));
        }
    }

    fn drawReadonly(param: *const abi.ParamView) void {
        var buf: [384]u8 = undefined;
        const name = param.desc.name;
        const text = switch (param.desc.typ) {
            .f32 => std.mem.printSentinel(&buf, "{s}: {d:.2}", .{ name, readF32(param, 0) }, 0) catch return,
            .i32 => std.mem.printSentinel(&buf, "{s}: {d}", .{ name, readI32(param, 0) }, 0) catch return,
            .str => std.mem.printSentinel(&buf, "{s}: {s}", .{ name, readStr(param) }, 0) catch return,
        };
        ig.igText("%s", text.ptr);
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    /// `"{name}##{param_index}"` — the index keys the widget to the parameter.
    /// `buf` belongs to the caller: the returned slice points into it.
    fn labelZ(buf: []u8, param: *const abi.ParamView) [:0]const u8 {
        return std.mem.printSentinel(buf, "{s}##{d}", .{ param.desc.name, param.param_index }, 0) catch "";
    }

    fn edit(module_index: usize, param: *const abi.ParamView, value: abi.EditValue) abi.Edit {
        return .{
            .module = @intCast(module_index),
            .param = param.param_index,
            .value = value,
        };
    }

    // ------------------------------------------------------------------
    // reading live values out of the host's parameter bytes
    // ------------------------------------------------------------------
    fn readF32(param: *const abi.ParamView, index: usize) f32 {
        const offset = index * @sizeOf(f32);
        if (offset + @sizeOf(f32) > param.value.len) return 0;
        return std.mem.bytesToValue(f32, param.value[offset..][0..@sizeOf(f32)]);
    }

    fn readI32(param: *const abi.ParamView, index: usize) i32 {
        const offset = index * @sizeOf(i32);
        if (offset + @sizeOf(i32) > param.value.len) return 0;
        return std.mem.bytesToValue(i32, param.value[offset..][0..@sizeOf(i32)]);
    }

    fn readStr(param: *const abi.ParamView) []const u8 {
        return std.mem.sliceTo(param.value, 0);
    }
};
