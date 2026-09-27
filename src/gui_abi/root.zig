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
//! plugin to update in place. Anything the plugin wants done comes back as an
//! `Intent` which the host applies *outside* the render pass.
//!
//! Growth is meant to be additive:
//!
//! - a new view adds a `ViewKind` variant, a `Model` section and (usually) a
//!   couple of `Intent` variants. Both switches that matter — the host draining
//!   intents and the plugin dispatching on the view — are exhaustive, so the
//!   compiler walks you through it.
//! - the plugin never gets a callable interface to the engine: everything a
//!   view needs is projected into the model, and everything it changes is an
//!   intent. That is what keeps the plugin engine-free (fast build, safe
//!   reloads) as the UI grows.
//! - intents reference host entities by *index* into a host-owned collection,
//!   never by name, path or pointer. They outlive the frame, so any bytes they
//!   carry are inline (`ParamText`).
//!
//! These structs are plain Zig (slices, tagged unions), not `extern`: both sides
//! compile this file with the same compiler in the same build, so the layout
//! cannot differ. Two checks protect against a *stale* plugin: `abi_version`
//! (bumped when this contract changes on purpose) and `layout_hash`, derived
//! from the memory layout the two sides must agree on — including the shared
//! types in `types/ui.zig`, so editing those without bumping the version is
//! caught instead of silently misread.
//!
//! Borrowed memory (module/param names, combo items, suffixes, live parameter
//! bytes) is always host memory, valid for the life of the process. The plugin
//! never frees or writes it.

const std = @import("std");
const builtin = @import("builtin");
const sokol = @import("sokol");
const ui = @import("types").ui;

/// Bump when this contract changes. The loader refuses a mismatched plugin.
pub const abi_version: u32 = 7;

/// File name `zig build gui` installs, relative to `zig-out/lib`.
pub const plugin_file_name = switch (builtin.os.tag) {
    .windows => "gui.dll",
    .macos => "libgui.dylib",
    else => "libgui.so",
};

/// Which view the editor shows. The host owns it (`SharedState.view`) and builds
/// the matching `Model` section; the plugin dispatches on it when drawing and
/// when routing input, so adding a variant here surfaces every place that has to
/// handle it.
pub const ViewKind = enum {
    darkroom,
    lighttable,
    // nodes, files …
};

/// Maximum intents the plugin may queue in one frame.
pub const max_intents = 16;

/// Inline capacity of a string value.
pub const max_str_bytes = 256;

// ============================================================================
// what the editor draws
// ============================================================================

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

/// The darkroom view: the pipeline being edited, module by module.
pub const DarkroomModel = struct {
    modules: []const ModuleView = &.{},
};

/// A texture the plugin may draw with `igImage`: `id` is the ImTextureID the
/// host built with `sokol.imgui.imtextureid(sg.View)`, so the GPU resource stays
/// host-owned and the plugin only holds a handle.
pub const ImageRef = struct {
    id: u64 = 0,
    width: f32 = 0,
    height: f32 = 0,
};

/// One entry of the catalog behind the lighttable. `thumb` is null until the
/// host has decoded and uploaded the thumbnail; `failed` marks entries whose
/// decode failed (the plugin still shows the name).
pub const CatalogItem = struct {
    name: []const u8 = "",
    thumb: ?ImageRef = null,
    failed: bool = false,
};

/// The lighttable view: the catalog the host has scanned.
pub const LighttableModel = struct {
    dir: []const u8 = "",
    items: []const CatalogItem = &.{},
};

/// What the editor draws this frame. Sections other than `SharedState.view` are
/// not populated. Built by the host whenever the graph changes; values are read
/// through `ParamView.value`, so value edits never need a rebuild.
pub const Model = struct {
    darkroom: DarkroomModel = .{},
    lighttable: LighttableModel = .{},
};

// ============================================================================
// what the plugin asks for
// ============================================================================

pub const ParamVector = struct {
    values: [4]f32 = @splat(0),
    count: u32 = 1,
};

/// Owned inline bytes: an intent outlives the frame that queued it, so it cannot
/// point at the plugin's stack.
pub const ParamText = struct {
    bytes: [max_str_bytes]u8 = @splat(0),
    len: u32 = 0,

    pub fn slice(self: *const ParamText) []const u8 {
        return self.bytes[0..@min(self.len, max_str_bytes)];
    }
};

/// A new parameter value. The variant *is* the parameter's type: `.scalar` is an
/// f32, `.integer` an i32, `.vector` an N-element f32 array, `.text` a string.
pub const ParamValue = union(enum) {
    scalar: f32,
    integer: i32,
    vector: ParamVector,
    text: ParamText,
};

/// Something the plugin wants the host to do. Queued in `SharedState.intents`
/// and applied after the frame (GPU work must not happen inside a render pass).
pub const Intent = union(enum) {
    /// Placeholder for empty queue slots.
    none,

    /// Change a module parameter. `module` indexes `Model.darkroom.modules`,
    /// `param` indexes that module's `params` array in the pipeline.
    set_param: struct {
        module: u32 = 0,
        param: u32 = 0,
        value: ParamValue = .{ .integer = 0 },
    },

    /// Show another view.
    switch_view: ViewKind,

    /// Load catalog item `index` into the pipeline and switch to the darkroom.
    open_image: u32,

    /// Rescan the catalog directory.
    reload_catalog,

    /// Ask the app to quit.
    quit,

    // grow here: add_module, connect, set_interacting, undo, …
};

// ============================================================================
// host-owned state
// ============================================================================

/// Per-view UI state. The plugin is the only writer; the host reads what it
/// needs (the blit uses `zoom`/`pan`). Kept here rather than in the plugin so it
/// survives a reload.
pub const DarkroomState = struct {
    zoom: f32 = 1,
    pan: [2]f32 = .{ 0, 0 },
    dragging: bool = false,
    last_mouse: [2]f32 = .{ 0, 0 },
    last_zoom: f32 = 1,
    panel_open: bool = true,
};

/// Per-view UI state for the lighttable: which entry is highlighted. Written by
/// the plugin (like the darkroom's zoom/pan), kept here so it survives a reload.
pub const LighttableState = struct {
    selected: u32 = 0,
};

/// State that outlives plugin generations. The plugin mutates it in place;
/// nothing else crosses the boundary.
pub const SharedState = struct {
    abi_version: u32 = abi_version,
    frame: u64 = 0,
    reloads: u32 = 0,

    /// active view, owned by the host (the plugin requests changes with intents)
    view: ViewKind = .darkroom,

    darkroom: DarkroomState = .{},
    lighttable: LighttableState = .{},
    // nodes: NodesState …

    intents: [max_intents]Intent = @splat(Intent.none),
    intent_count: u32 = 0,

    /// Queue an intent. Returns false (dropping it) if this frame's queue is
    /// already full.
    pub fn push(self: *SharedState, intent: Intent) bool {
        if (self.intent_count >= max_intents) return false;
        self.intents[self.intent_count] = intent;
        self.intent_count += 1;
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
    @setEvalBranchQuota(100_000); // recursive structure walk + FNV per name
    var seed: u64 = 14695981039346656037;
    seed = mix(seed, typeHash(Model));
    seed = mix(seed, typeHash(SharedState));
    seed = mix(seed, typeHash(Intent));
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
