//! UI vocabulary for pipeline module parameters.
//!
//! This is the *shared* definition: the engine's module descriptors
//! (`engine/modules/api.zig` re-exports these, and every `module.zig` writes
//! `.params` / `.params_ui` in these terms) and the GUI ABI
//! (`gui_abi/root.zig` hands the same values to the hot-reloadable plugin) both
//! use these exact types. There is one definition of what a slider is, not two
//! that have to be kept in sync by hand.
//!
//! Kept dependency-free on purpose: it lives in the `types` module, which has no
//! imports, so the GUI plugin can import it without pulling in any engine code.

const std = @import("std");

/// How a parameter's value bytes are encoded.
pub const ParamType = enum {
    i32,
    f32,
    str,
};

pub const ParamDesc = struct {
    name: []const u8,
    len: u32,
    typ: ParamType,
};

pub const Slider = struct {
    min: f32,
    max: f32,
    step: f32 = 0.0, // 0 = full precision (1/tick-resolution)
    suffix: ?[]const u8 = null,
};

pub const Sliders = struct {
    /// number of scalar elements (must match the param's `len`)
    n: usize,
    min: f32,
    max: f32,
    step: f32 = 0.01,
    suffixes: ?[]const []const u8 = null,
    /// optional per-element labels shown instead of "[i]"
    labels: ?[]const []const u8 = null,
};

pub const Combo = struct {
    items: []const []const u8,
};

/// Which widget an editor should use for a parameter. The control must match
/// the param type (`slider`/`combo`/`checkbox` for i32/f32, `text` for str).
pub const Control = union(enum) {
    slider: Slider,
    sliders: Sliders,
    combo: Combo,
    checkbox,
    text,
    readonly,
};

/// UI hint for a module parameter. `name` must match a `ParamDesc` in the
/// module's `params` list (matched by name, not position — a module may expose
/// only the params it wants, in any order).
pub const ParamUI = struct {
    name: []const u8,
    control: Control,
};
