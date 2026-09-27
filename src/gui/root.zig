//! GUI plugin root — the *entire* plugin surface.
//!
//! The plugin is stateless by design: the host owns the pipeline, the blit
//! resources, the UI model and all mutable state (`abi.SharedState`), so a
//! reload is `dlclose` + `dlopen` with nothing to save, restore or free. That
//! also keeps the plugin's module graph small (ImGui + sokol's event type),
//! which is what makes an edit rebuild in about a second.
//!
//! Keep the engine out of here: this side is only good at drawing widgets.

const sokol = @import("sokol");
const sapp = sokol.app;

const abi = @import("abi");

const Darkroom = @import("./views/darkroom.zig").Darkroom;
const Lighttable = @import("./views/lighttable.zig").Lighttable;
const MenuBar = @import("./components/menu_bar.zig").MenuBar;

pub fn gui_abi_version() callconv(.c) u32 {
    return abi.abi_version;
}

/// Fingerprint of the memory layout this plugin was built against; the loader
/// compares it so a stale plugin (e.g. built after editing `types/ui.zig` while
/// the app kept running the old contract) is refused instead of misread.
pub fn gui_abi_layout() callconv(.c) u64 {
    return abi.layout_hash;
}

/// Draw the menu bar and the active view's widgets. The menu bar is drawn before
/// the view so imgui offsets the viewport's work area for it.
pub fn gui_draw(state: *abi.SharedState, model: *const abi.Model) callconv(.c) void {
    MenuBar.draw(state);
    switch (state.view) {
        .darkroom => Darkroom.draw(state, &model.darkroom),
        .lighttable => Lighttable.draw(state, &model.lighttable),
    }
}

/// Mouse/keyboard input that ImGui did not consume. Both views are imgui
/// widgets, so only the image view needs raw input (pan/zoom).
pub fn gui_event(state: *abi.SharedState, ev: [*c]const sapp.Event) callconv(.c) void {
    switch (state.view) {
        .darkroom => Darkroom.event(state, ev),
        .lighttable => {},
    }
}

comptime {
    @export(&gui_abi_version, .{ .name = "gui_abi_version" });
    @export(&gui_abi_layout, .{ .name = "gui_abi_layout" });
    @export(&gui_draw, .{ .name = "gui_draw" });
    @export(&gui_event, .{ .name = "gui_event" });

    // ABI drift guard: these must be exactly the signatures the host looks up.
    if (@TypeOf(&gui_abi_version) != *const abi.Entry.VersionFn) @compileError("gui_abi_version signature mismatch");
    if (@TypeOf(&gui_abi_layout) != *const abi.Entry.LayoutFn) @compileError("gui_abi_layout signature mismatch");
    if (@TypeOf(&gui_draw) != *const abi.Entry.DrawFn) @compileError("gui_draw signature mismatch");
    if (@TypeOf(&gui_event) != *const abi.Entry.EventFn) @compileError("gui_event signature mismatch");
}
