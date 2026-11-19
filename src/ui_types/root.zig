//! UI hint types used by the module descriptor and the editor.

pub const ui = @import("ui.zig");

pub const ParamUI = ui.ParamUI;
pub const Control = ui.Control;
pub const Slider = ui.Slider;
pub const Sliders = ui.Sliders;
pub const Combo = ui.Combo;

test {
    @import("std").testing.refAllDecls(@This());
}
