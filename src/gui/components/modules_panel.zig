//! Renders one collapsible section per module in the live pipeline.
//!
//! The module list comes from the session's pipeline pool; each parameter's
//! descriptor and UI hint are the engine's own `types/ui.zig` types, read
//! through live `Param.bytes`. Edits go straight to the session.

const std = @import("std");
const ig = @import("cimgui");
const session = @import("session");
const pie = @import("pie");
const ui = @import("types").ui;

/// Inline capacity of a string parameter, matching the engine's `max_str_bytes`.
const max_str_bytes = 256;

pub const ModulesPanel = struct {
    pub fn draw(s: *session.Session, panel_open: *bool) void {
        // no `MenuBar` flag: it reserves a menu-bar strip we never draw into,
        // which shows up as a blank band under the title bar.
        if (!ig.igBegin("Modules", panel_open, ig.ImGuiWindowFlags_None)) {
            ig.igEnd();
            return;
        }
        defer ig.igEnd();

        ig.igText("pipeline modules");
        ig.igSeparator();

        var index: usize = 0;
        var it = s.pipeline.module_pool.liveHandles();
        while (it.next()) |handle| {
            const mod = s.pipeline.module_pool.getPtr(handle) catch continue;
            drawModule(s, handle, mod, index);
            index += 1;
        }
    }

    fn drawModule(
        s: *session.Session,
        handle: pie.pipeline.ModuleHandle,
        mod: *pie.api.Module,
        module_index: usize,
    ) void {
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

        for (mod.params_ui) |maybe_ui| {
            const param_ui = maybe_ui orelse continue;
            const idx = mod.getParamIndex(param_ui.name) catch continue;
            const param = mod.params[idx] orelse continue;
            drawParam(s, handle, &param, param_ui.control, @intCast(idx));
        }
    }

    fn drawParam(
        s: *session.Session,
        handle: pie.pipeline.ModuleHandle,
        param: *const pie.api.Param,
        control: ui.Control,
        param_index: u32,
    ) void {
        switch (control) {
            .slider => |slider| drawSlider(s, handle, param, slider, param_index),
            .sliders => |sliders| drawSliders(s, handle, param, sliders, param_index),
            .combo => |combo| drawCombo(s, handle, param, combo, param_index),
            .checkbox => drawCheckbox(s, handle, param, param_index),
            .text => drawText(s, handle, param, param_index),
            .readonly => drawReadonly(param),
        }
    }

    fn drawSlider(
        s: *session.Session,
        handle: pie.pipeline.ModuleHandle,
        param: *const pie.api.Param,
        slider: ui.Slider,
        param_index: u32,
    ) void {
        var label_buf: [160]u8 = undefined;
        const label = labelZ(&label_buf, param, param_index);
        ig.igPushIDInt(@intCast(param_index));
        defer ig.igPopID();

        const suffix = slider.suffix orelse "";
        switch (param.desc.typ) {
            .f32 => {
                var value = readF32(param, 0);
                var format_buf: [32]u8 = undefined;
                const format = std.mem.printSentinel(&format_buf, "%.2f{s}", .{suffix}, 0) catch "%.2f";
                if (ig.igSliderFloatEx(label.ptr, &value, slider.min, slider.max, format.ptr, 0)) {
                    s.setParam(handle, param.desc.name, f32, value);
                }
            },
            .i32 => {
                var value = readI32(param, 0);
                if (ig.igSliderInt(label.ptr, &value, @intFromFloat(@floor(slider.min)), @intFromFloat(@ceil(slider.max)))) {
                    s.setParam(handle, param.desc.name, i32, value);
                }
            },
            .str => {},
        }
    }

    fn drawSliders(
        s: *session.Session,
        handle: pie.pipeline.ModuleHandle,
        param: *const pie.api.Param,
        sliders: ui.Sliders,
        param_index: u32,
    ) void {
        if (param.desc.typ != .f32) return; // only float arrays are supported for now

        // declared element count, bounded by the storage the param actually has
        const n = @min(sliders.n, @as(usize, param.desc.len));
        if (n == 0 or n > 4) return; // only 2/3/4-element vectors can be committed

        ig.igPushIDInt(@intCast(param_index));
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
            switch (n) {
                2 => s.setParam(handle, param.desc.name, [2]f32, values[0..2].*),
                3 => s.setParam(handle, param.desc.name, [3]f32, values[0..3].*),
                4 => s.setParam(handle, param.desc.name, [4]f32, values[0..4].*),
                else => {},
            }
        }
    }

    fn drawCombo(
        s: *session.Session,
        handle: pie.pipeline.ModuleHandle,
        param: *const pie.api.Param,
        combo: ui.Combo,
        param_index: u32,
    ) void {
        var label_buf: [160]u8 = undefined;
        const label = labelZ(&label_buf, param, param_index);

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

        ig.igPushIDInt(@intCast(param_index));
        defer ig.igPopID();

        var current: c_int = if (param.desc.typ == .i32) readI32(param, 0) else 0;
        if (ig.igCombo(label.ptr, &current, @ptrCast(items_z.ptr))) {
            s.setParam(handle, param.desc.name, i32, @intCast(current));
        }
    }

    fn drawCheckbox(s: *session.Session, handle: pie.pipeline.ModuleHandle, param: *const pie.api.Param, param_index: u32) void {
        var label_buf: [160]u8 = undefined;
        const label = labelZ(&label_buf, param, param_index);
        var value = readI32(param, 0) != 0;
        if (ig.igCheckbox(label.ptr, &value)) {
            s.setParam(handle, param.desc.name, i32, if (value) 1 else 0);
        }
    }

    fn drawText(s: *session.Session, handle: pie.pipeline.ModuleHandle, param: *const pie.api.Param, param_index: u32) void {
        var label_buf: [160]u8 = undefined;
        const label = labelZ(&label_buf, param, param_index);

        var buf: [max_str_bytes]u8 = @splat(0);
        const current = readStr(param);
        const n = @min(current.len, buf.len - 1);
        @memcpy(buf[0..n], current[0..n]);

        ig.igPushIDInt(@intCast(param_index));
        defer ig.igPopID();

        if (ig.igInputText(label.ptr, &buf, buf.len, ig.ImGuiInputTextFlags_None)) {
            const text = std.mem.sliceTo(&buf, 0);
            s.setParam(handle, param.desc.name, []const u8, text);
        }
    }

    fn drawReadonly(param: *const pie.api.Param) void {
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
    fn labelZ(buf: []u8, param: *const pie.api.Param, param_index: u32) [:0]const u8 {
        return std.mem.printSentinel(buf, "{s}##{d}", .{ param.desc.name, param_index }, 0) catch "";
    }

    // ------------------------------------------------------------------
    // reading live values out of the parameter's bytes
    // ------------------------------------------------------------------
    fn readF32(param: *const pie.api.Param, index: usize) f32 {
        const offset = index * @sizeOf(f32);
        if (offset + @sizeOf(f32) > param.bytes.len) return 0;
        return std.mem.bytesToValue(f32, param.bytes[offset..][0..@sizeOf(f32)]);
    }

    fn readI32(param: *const pie.api.Param, index: usize) i32 {
        const offset = index * @sizeOf(i32);
        if (offset + @sizeOf(i32) > param.bytes.len) return 0;
        return std.mem.bytesToValue(i32, param.bytes[offset..][0..@sizeOf(i32)]);
    }

    fn readStr(param: *const pie.api.Param) []const u8 {
        return std.mem.sliceTo(param.bytes, 0);
    }
};
