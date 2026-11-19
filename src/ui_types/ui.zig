//! UI vocabulary for pipeline module parameters.
//!
//! The parameter *description* (`ParamType`/`ParamDesc`) lives with the module
//! API in `module_api.zig`; this file is only the editor-facing side: the
//! widgets a parameter can be drawn with.
//!
//! Kept dependency-free on purpose: it lives in the `types` module, which has
//! no imports.

const std = @import("std");

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
