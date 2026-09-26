//! ABI between the host executable and the hot-reloadable GUI plugin.
//!
//! Design rule: **the plugin owns no state and no GPU resources**. The host
//! keeps the pipeline, the blit resources and the UI model, so a reload is
//! `dlclose` + `dlopen` with nothing to hand over, and the plugin's module
//! graph stays tiny (it only needs this contract, the shared UI vocabulary in
//! `types/ui.zig`, ImGui and sokol's event type).
//!
//! Each frame the host builds a `Model` (pointers into its own pipeline, never
//! mutated by the plugin) and passes the host-owned `SharedState` for the
//! plugin to update in place. Widget edits come back as `Edit` intents which the
//! host applies *outside* the render pass.
//!
//! These structs are plain Zig (slices, tagged unions), not `extern`: both sides
//! compile this file with the same compiler in the same build, so the layout
//! cannot differ. Two checks protect against a *stale* plugin: `abi_version`
//! (bumped when this contract changes on purpose) and `layout_hash`, which is
//! derived from the memory layout the two sides must agree on — including the
//! shared types in `types/ui.zig`, so editing those without bumping the version
//! is still caught instead of silently misread.
//!
//! Borrowed memory (module/param names, combo items, suffixes, live parameter
//! bytes) is always host memory, valid for the life of the process. The plugin
//! never frees or writes it.

const std = @import("std");
const builtin = @import("builtin");
const sokol = @import("sokol");
const ui = @import("types").ui;

/// Bump when this contract changes. The loader refuses a mismatched plugin.
pub const abi_version: u32 = 5;

/// File name `zig build gui` installs, relative to `zig-out/lib`.
pub const plugin_file_name = switch (builtin.os.tag) {
    .windows => "gui.dll",
    .macos => "libgui.dylib",
    else => "libgui.so",
};

/// Maximum parameter edits the plugin may queue in one frame.
pub const max_edits = 16;

/// Inline capacity of a string edit.
pub const max_str_bytes = 256;

/// One parameter the editor draws: where it lives (`param_index` into the
/// module's `params`), what it is (`desc`, the engine's own descriptor), how to
/// draw it (`control`, the engine's own UI hint) and its live value bytes
/// (`value`, host-owned and read-only for the plugin).
pub const ParamView = struct {
    param_index: u32 = 0,
    desc: ui.ParamDesc = .{ .name = "", .len = 0, .typ = .i32 },
    control: ui.Control = .readonly,
    value: []const u8 = "",
};

pub const ModuleView = struct {
    /// module type, e.g. "i-raw"
    name: []const u8 = "",
    params: []const ParamView = &.{},
};

/// What the editor draws: a slice of host-owned `ModuleView`s, rebuilt whenever
/// the graph changes. Values are read through `ParamView.value`, so value edits
/// never need a rebuild.
pub const Model = struct {
    modules: []const ModuleView = &.{},
};

pub const EditVector = struct {
    values: [4]f32 = @splat(0),
    count: u32 = 1,
};

/// Owned inline bytes: an edit outlives the frame that queued it, so it cannot
/// point at the plugin's stack.
pub const EditText = struct {
    bytes: [max_str_bytes]u8 = @splat(0),
    len: u32 = 0,

    pub fn slice(self: *const EditText) []const u8 {
        return self.bytes[0..@min(self.len, max_str_bytes)];
    }
};

/// The new value of an edited parameter. The variant *is* the parameter's type:
/// `.scalar` is an f32, `.integer` an i32, `.vector` an N-element f32 array,
/// `.text` a string.
pub const EditValue = union(enum) {
    scalar: f32,
    integer: i32,
    vector: EditVector,
    text: EditText,
};

/// A parameter change requested by the plugin, queued in `SharedState.edits`
/// and applied by the host after the frame (GPU work must not happen inside a
/// render pass). `module` indexes `Model.modules`, `param` indexes that
/// module's `params` array in the pipeline.
pub const Edit = struct {
    module: u32 = 0,
    param: u32 = 0,
    value: EditValue = .{ .integer = 0 },

    /// Placeholder for empty queue slots.
    pub const none: Edit = .{};
};

/// Host-owned state that outlives plugin generations. The plugin mutates it in
/// place; nothing else crosses the boundary.
pub const SharedState = struct {
    abi_version: u32 = abi_version,
    frame: u64 = 0,
    reloads: u32 = 0,

    // view state, owned by the plugin (mouse input); the host uses it for the blit
    zoom: f32 = 1,
    pan: [2]f32 = .{ 0, 0 },
    dragging: bool = false,
    last_mouse: [2]f32 = .{ 0, 0 },
    last_zoom: f32 = 1,
    panel_open: bool = true,

    /// Edits the plugin queued this frame. Queuing one means "re-run the
    /// pipeline"; the host drains the queue outside the render pass.
    edits: [max_edits]Edit = @splat(Edit.none),
    edit_count: u32 = 0,

    /// Queue a parameter change. Returns false (dropping it) if this frame's
    /// queue is already full.
    pub fn pushEdit(self: *SharedState, edit: Edit) bool {
        if (self.edit_count >= max_edits) return false;
        self.edits[self.edit_count] = edit;
        self.edit_count += 1;
        return true;
    }
};

pub const Entry = struct {
    pub const VersionFn = fn () callconv(.c) u32;
    pub const LayoutFn = fn () callconv(.c) u64;
    pub const DrawFn = fn (state: *SharedState, model: *const Model) callconv(.c) void;
    pub const EventFn = fn (state: *SharedState, ev: [*c]const sokol.app.Event) callconv(.c) void;

    version: *const VersionFn,
    layout: *const LayoutFn,
    draw: *const DrawFn,
    event: *const EventFn,
};

/// Fingerprint of the memory the host and the plugin both interpret: struct
/// sizes, field order/offsets and union/enum variant order, transitively
/// (including `types/ui.zig`). Structural on purpose — two types that are laid
/// out identically are interchangeable here, and it is the *interpretation* of
/// the bytes that must match, not the names.
pub const layout_hash: u64 = blk: {
    var seed: u64 = 14695981039346656037;
    seed = mix(seed, typeHash(Model));
    seed = mix(seed, typeHash(SharedState));
    seed = mix(seed, typeHash(Edit));
    break :blk seed;
};

fn mix(seed: u64, value: u64) u64 {
    return (seed ^ value) *% 1099511628211;
}

fn nameHash(comptime name: []const u8) u64 {
    var h: u64 = 14695981039346656037;
    for (name) |c| h = (h ^ c) *% 1099511628211;
    return h;
}

fn typeHash(comptime T: type) u64 {
    const info = @typeInfo(T);
    var h = mix(14695981039346656037, @sizeOf(T));
    h = mix(h, @alignOf(T));
    switch (info) {
        .@"struct" => |s| {
            for (s.field_names, s.field_types) |name, FieldType| {
                h = mix(h, nameHash(name));
                h = mix(h, @offsetOf(T, name));
                h = mix(h, typeHash(FieldType));
            }
            h = mix(h, s.field_names.len);
        },
        .@"union" => |u| {
            for (u.field_names, u.field_types) |name, FieldType| {
                h = mix(h, nameHash(name));
                h = mix(h, typeHash(FieldType));
            }
            h = mix(h, u.field_names.len);
        },
        .@"enum" => |e| {
            for (e.field_names, e.field_values) |name, value| {
                h = mix(h, nameHash(name));
                h = mix(h, @bitCast(@as(i64, value)));
            }
            h = mix(h, e.field_names.len);
        },
        .optional => |o| h = mix(h, typeHash(o.child)),
        .pointer => |p| h = mix(h, typeHash(p.child)),
        .array => |a| {
            h = mix(h, a.len);
            h = mix(h, typeHash(a.child));
        },
        else => {},
    }
    return h;
}
