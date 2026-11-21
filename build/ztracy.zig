//! Build glue for the ztracy bindings.
//!
//! Upstream `ztracy`'s own `build.zig` adds the Apple SDK framework path
//! `System/Library/Frameworks`, but `zig-gamedev/system_sdk` lays its macOS
//! tree out as `macos12/System/Library/Frameworks`. Zig treats the missing
//! directory as a hard error, so `-Denable_ztracy=true` cannot build on macOS
//! with the dependency as-is.
//!
//! The framework path is not needed anyway: the Tracy client on macOS only
//! uses libSystem (mach clocks/threads, pthreads) and libc++. So we build the
//! same two artifacts ztracy's `build.zig` does, minus that path, from the
//! hash-pinned source in `build.zig.zon`.

const std = @import("std");
const Build = std.Build;

pub const Options = struct {
    /// The resolved `ztracy` package dependency.
    dependency: *Build.Dependency,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    /// Compiles Tracy markers in; otherwise ztracy resolves to no-op stubs.
    enable: bool,
    /// Only collect trace data while a profiler is connected.
    on_demand: bool = true,
    /// Capture a callstack of this depth at every zone/message (0 = off).
    callstack: u32 = 0,
};

pub const Tracy = struct {
    /// `@import("ztracy")` bindings module.
    module: *Build.Module,
    /// The Tracy client library; link it into the final executable.
    lib: *Build.Step.Compile,
};

pub fn create(b: *Build, opts: Options) Tracy {
    const dep = opts.dependency;

    const options_step = b.addOptions();
    options_step.addOption(bool, "enable_ztracy", opts.enable);
    options_step.addOption(bool, "enable_fibers", false);
    options_step.addOption(bool, "on_demand", opts.on_demand);
    options_step.addOption(u32, "callstack", opts.callstack);

    // C bindings for TracyC.h; TRACY_ENABLE must agree with the client library.
    const translate_c = b.addTranslateC(.{
        .root_source_file = dep.path("libs/tracy/tracy/TracyC.h"),
        .target = opts.target,
        .optimize = opts.optimize,
        .link_libc = true,
    });
    translate_c.addIncludePath(dep.path("libs/tracy/tracy"));
    translate_c.defineCMacro("TRACY_ENABLE", "");
    translate_c.defineCMacro("TRACY_IMPORTS", "");
    // `TracyCZoneCtx` gains a `connectionId` field under TRACY_ON_DEMAND; the
    // bindings and the client library must agree on that layout or every
    // `Text`/`Name` call misreads its arguments.
    if (opts.on_demand) translate_c.defineCMacro("TRACY_ON_DEMAND", "");
    // TRACY_USE_CALLSTACK makes ztracy emit the callstack entry points, but
    // ztracy gates that on `@hasDecl(c, "TRACY_HAS_CALLSTACK")` and TracyC.h
    // never includes TracyCallstack.h, so the macro would be missing. Mirror
    // TracyCallstack.h's platform values here instead of pulling in a C++
    // header through translate-c.
    if (opts.callstack > 0) {
        var depth_buffer: [16]u8 = undefined;
        const depth = std.fmt.printInt(&depth_buffer, @as(u32, opts.callstack), 10, .lower, .{});
        translate_c.defineCMacro("TRACY_USE_CALLSTACK", "");
        translate_c.defineCMacro("TRACY_CALLSTACK", depth_buffer[0..depth]);
        translate_c.defineCMacro("TRACY_HAS_CALLSTACK", switch (opts.target.result.os.tag) {
            .windows => "1",
            .linux => "3",
            .macos => "4",
            else => "2",
        });
    }

    const module = b.addModule("ztracy", .{
        .root_source_file = dep.path("src/ztracy.zig"),
        .imports = &.{
            .{ .name = "ztracy_options", .module = options_step.createModule() },
        },
    });
    module.addImport("c", translate_c.createModule());

    const lib = b.addLibrary(.{
        .name = "tracy",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = opts.target,
            .optimize = opts.optimize,
        }),
    });
    lib.root_module.addIncludePath(dep.path("libs/tracy/tracy"));
    lib.root_module.addCSourceFile(.{
        .file = dep.path("libs/tracy/TracyClient.cpp"),
        .flags = &.{"-fno-sanitize=undefined"},
    });
    if (opts.enable) lib.root_module.addCMacro("TRACY_ENABLE", "");
    if (opts.on_demand) lib.root_module.addCMacro("TRACY_ON_DEMAND", "");
    lib.root_module.link_libc = true;
    lib.root_module.link_libcpp = opts.target.result.abi != .msvc;
    if (opts.target.result.abi == .msvc) lib.root_module.addCMacro("fileno", "_fileno");

    switch (opts.target.result.os.tag) {
        .windows => {
            lib.root_module.linkSystemLibrary("ws2_32", .{});
            lib.root_module.linkSystemLibrary("dbghelp", .{});
            lib.root_module.linkSystemLibrary("secur32", .{});
        },
        else => {},
    }

    return .{ .module = module, .lib = lib };
}
