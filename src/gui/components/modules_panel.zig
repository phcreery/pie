const std = @import("std");
const pie = @import("pie");
const ig = @import("cimgui");

/// Renders one collapsible section per module in the pipeline. Each section
/// shows a control per param that has a `params_ui` entry in the module desc.
/// When a control changes value it writes through to the pipeline param and
/// signals the owner (via `rerun_requested`) to re-run the pipeline.
pub const ModulesPanel = struct {
    is_open: bool = true,

    const Self = @This();

    pub fn init() Self {
        return Self{};
    }

    pub fn draw(self: *Self, pipeline: *pie.Pipeline, rerun_requested: *bool) void {
        if (!ig.igBegin("Modules", &self.is_open, ig.ImGuiWindowFlags_MenuBar)) {
            ig.igEnd();
            return;
        }
        defer ig.igEnd();

        ig.igText("pipeline modules");
        ig.igSeparator();

        var handles = pipeline.module_pool.liveHandles();
        while (handles.next()) |mod_handle| {
            const mod = pipeline.module_pool.getPtr(mod_handle) catch continue;
            drawModule(pipeline, rerun_requested, mod_handle, mod);
        }
    }

    fn drawModule(
        pipeline: *pie.Pipeline,
        rerun_requested: *bool,
        mod_handle: pie.pipeline.ModuleHandle,
        mod: *pie.Module,
    ) void {
        ig.igPushIDPtr(@ptrCast(mod));
        defer ig.igPopID();

        // header row: name + type
        var header_buf: [128]u8 = undefined;
        const header = std.mem.printSentinel(&header_buf, "{s}##{x}", .{ mod.desc.name, mod_handle.id }, 0) catch return;
        const open = ig.igCollapsingHeader(
            header.ptr,
            ig.ImGuiTreeNodeFlags_OpenOnArrow | ig.ImGuiTreeNodeFlags_OpenOnDoubleClick | ig.ImGuiTreeNodeFlags_DefaultOpen,
        );
        if (!open) return;

        ig.igIndentEx(8.0);
        defer ig.igUnindentEx(8.0);

        // one row per param
        for (mod.desc.params, mod.desc.params_ui, 0..) |maybe_param, maybe_ui, param_idx| {
            const param_desc = maybe_param orelse continue;
            const ui = maybe_ui orelse continue;

            // read current value
            const param = mod.getParamPtr(param_desc.name) catch continue;

            switch (ui.control) {
                .slider => |slider| drawSlider(pipeline, rerun_requested, mod_handle, param_desc.name, param, slider, param_idx),
                .sliders => |sliders| drawSliders(pipeline, rerun_requested, mod_handle, param_desc.name, param, sliders, param_idx),
                .combo => |combo| drawCombo(pipeline, rerun_requested, mod_handle, param_desc.name, param, combo.items, param_idx),
                .checkbox => drawCheckbox(pipeline, rerun_requested, mod_handle, param_desc.name, param, param_idx),
                .text => drawText(pipeline, rerun_requested, mod_handle, param_desc.name, param, param_idx),
                .readonly => drawReadonly(param_desc.name, param),
            }
        }
    }

    fn drawSlider(
        pipeline: *pie.Pipeline,
        rerun_requested: *bool,
        mod_handle: pie.pipeline.ModuleHandle,
        param_name: []const u8,
        param: *pie.api.Param,
        slider: pie.api.ParamUI.Slider,
        param_idx: usize,
    ) void {
        var label_buf: [128]u8 = undefined;
        const label = std.mem.printSentinel(
            &label_buf,
            "{s}##{d}",
            .{ param_name, param_idx },
            0,
        ) catch return;

        ig.igPushIDInt(@intCast(param_idx));
        defer ig.igPopID();
        // ig.igSetNextItemWidth(-1); // fill the row

        switch (param.desc.typ) {
            .f32 => {
                var v = param.get(f32);
                var format_buf: [32]u8 = undefined;
                const format = std.mem.printSentinel(
                    &format_buf,
                    "%.2f{s}",
                    .{slider.suffix orelse ""},
                    0,
                ) catch "%.2f";
                const changed = ig.igSliderFloatEx(label.ptr, &v, slider.min, slider.max, format.ptr, 0);
                if (changed) {
                    pipeline.setModuleParam(mod_handle, param_name, f32, v) catch {};
                    rerun_requested.* = true;
                }
            },
            .i32 => {
                var v = param.get(i32);
                const changed = ig.igSliderInt(label.ptr, &v, @intFromFloat(@floor(slider.min)), @intFromFloat(@ceil(slider.max)));
                if (changed) {
                    pipeline.setModuleParam(mod_handle, param_name, i32, v) catch {};
                    rerun_requested.* = true;
                }
            },
            .str => {},
        }
    }

    fn drawSliders(
        pipeline: *pie.Pipeline,
        rerun_requested: *bool,
        mod_handle: pie.pipeline.ModuleHandle,
        param_name: []const u8,
        param: *pie.api.Param,
        sliders: pie.api.ParamUI.Sliders,
        param_idx: usize,
    ) void {
        if (param.desc.typ != .f32) return; // only float arrays supported for now

        // read the current value as a slice of n f32
        ig.igPushIDInt(@intCast(param_idx));
        defer ig.igPopID();

        // header label
        var label_buf: [128]u8 = undefined;
        const label = std.mem.printSentinel(&label_buf, "{s}", .{param_name}, 0) catch return;
        ig.igText("{s}", label.ptr);

        // read the current value as n f32 (dispatch on the param's static len)
        var values: [16]f32 = @splat(0);
        const n: usize = @intCast(param.desc.len);
        if (n > values.len or sliders.n != n) return;        switch (n) {
            2 => @memcpy(values[0..n], &(param.get([2]f32))),
            3 => @memcpy(values[0..n], &(param.get([3]f32))),
            4 => @memcpy(values[0..n], &(param.get([4]f32))),
            else => return,
        }

        var changed = false;
        for (0..n) |i| {
            const suffix = if (sliders.suffixes) |s| if (i < s.len) s[i] else "" else "";
            var fmt_buf: [32]u8 = undefined;
            const fmt = std.mem.printSentinel(&fmt_buf, "%.3f{s}", .{suffix}, 0) catch "%.3f";
            var id_buf: [64]u8 = undefined;
            const id = std.mem.printSentinel(&id_buf, "[{d}]", .{i}, 0) catch return;

            const changed_i = ig.igSliderFloatEx(
                id.ptr,
                &values[i],
                sliders.min,
                sliders.max,
                fmt.ptr,
                0,
            );
            changed = changed or changed_i;
        }

        if (changed) {
            switch (n) {
                2 => pipeline.setModuleParam(mod_handle, param_name, [2]f32, values[0..2].*) catch {},
                3 => pipeline.setModuleParam(mod_handle, param_name, [3]f32, values[0..3].*) catch {},
                4 => pipeline.setModuleParam(mod_handle, param_name, [4]f32, values[0..4].*) catch {},
                else => {},
            }
            rerun_requested.* = true;
        }
    }

    fn drawCombo(
        pipeline: *pie.Pipeline,
        rerun_requested: *bool,
        mod_handle: pie.pipeline.ModuleHandle,
        param_name: []const u8,
        param: *pie.api.Param,
        items: []const []const u8,
        param_idx: usize,
    ) void {
        var label_buf: [128]u8 = undefined;
        const label = std.mem.printSentinel(
            &label_buf,
            "{s}##{d}",
            .{ param_name, param_idx },
            0,
        ) catch return;

        // build the zero-separated items string imgui wants ("a\x00b\x00\x00")
        var items_buf: [512]u8 = undefined;
        var pos: usize = 0;
        for (items) |item| {
            if (pos + item.len + 1 > items_buf.len) break;
            @memcpy(items_buf[pos..][0..item.len], item);
            pos += item.len;
            items_buf[pos] = 0;
            pos += 1;
        }
        items_buf[pos] = 0;
        const items_z = items_buf[0 .. pos + 1];

        ig.igPushIDInt(@intCast(param_idx));
        defer ig.igPopID();
        // ig.igSetNextItemWidth(-1);

        const current_item = switch (param.desc.typ) {
            .i32 => param.get(i32),
            else => 0,
        };
        var cur: c_int = @intCast(current_item);
        const changed = ig.igCombo(label.ptr, &cur, @ptrCast(items_z.ptr));
        if (changed) {
            pipeline.setModuleParam(mod_handle, param_name, i32, cur) catch {};
            rerun_requested.* = true;
        }
    }

    fn drawCheckbox(
        pipeline: *pie.Pipeline,
        rerun_requested: *bool,
        mod_handle: pie.pipeline.ModuleHandle,
        param_name: []const u8,
        param: *pie.api.Param,
        param_idx: usize,
    ) void {
        var label_buf: [128]u8 = undefined;
        const label = std.mem.printSentinel(
            &label_buf,
            "{s}##{d}",
            .{ param_name, param_idx },
            0,
        ) catch return;

        var value = param.get(i32) != 0;
        const changed = ig.igCheckbox(label.ptr, &value);
        if (changed) {
            pipeline.setModuleParam(mod_handle, param_name, i32, @as(i32, if (value) 1 else 0)) catch {};
            rerun_requested.* = true;
        }
    }

    fn drawText(
        pipeline: *pie.Pipeline,
        rerun_requested: *bool,
        mod_handle: pie.pipeline.ModuleHandle,
        param_name: []const u8,
        param: *pie.api.Param,
        param_idx: usize,
    ) void {
        var label_buf: [128]u8 = undefined;
        const label = std.mem.printSentinel(
            &label_buf,
            "{s}##{d}",
            .{ param_name, param_idx },
            0,
        ) catch return;

        var buf: [256]u8 = @splat(0);
        const cur = param.get([]const u8);
        const n = @min(cur.len, buf.len - 1);
        @memcpy(buf[0..n], cur[0..n]);

        ig.igPushIDInt(@intCast(param_idx));
        defer ig.igPopID();
        // ig.igSetNextItemWidth(-1);
        const changed = ig.igInputText(label.ptr, &buf, buf.len, ig.ImGuiInputTextFlags_None);
        if (changed) {
            const s = std.mem.sliceTo(&buf, 0);
            pipeline.setModuleParam(mod_handle, param_name, []const u8, s) catch {};
            rerun_requested.* = true;
        }
    }

    fn drawReadonly(param_name: []const u8, param: *pie.api.Param) void {
        var buf: [256]u8 = undefined;
        const text = switch (param.desc.typ) {
            .f32 => std.mem.printSentinel(&buf, "{s}: {d:.2}", .{ param_name, param.get(f32) }, 0) catch return,
            .i32 => std.mem.printSentinel(&buf, "{s}: {d}", .{ param_name, param.get(i32) }, 0) catch return,
            .str => std.mem.printSentinel(&buf, "{s}: {s}", .{ param_name, param.get([]const u8) }, 0) catch return,
        };
        ig.igText("%s", text.ptr);
    }
};
