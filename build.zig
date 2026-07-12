const std = @import("std");
const builtin = @import("builtin");
const Build = std.Build;
const sokol = @import("sokol");
const cimgui = @import("cimgui");

pub fn build(b: *Build) !void {
    // CONFIGURATION
    const target = b.standardTargetOptions(.{
        .default_target = .{ .abi = .msvc },
    });
    // for testing only, forces a native build
    // const target = b.resolveTargetQuery(.{
    //     .ofmt = .c,
    // });
    const optimize = b.standardOptimizeOption(.{});
    const opts = .{ .target = target, .optimize = optimize };

    const opt_docking = b.option(bool, "docking", "Build with docking support") orelse false;

    // Get the matching Zig module name, C header search path and C library for
    // vanilla imgui vs the imgui docking branch.
    const cimgui_conf = cimgui.getConfig(opt_docking);

    // DEPENDENCIES
    // note that the sokol dependency is built with `.with_sokol_imgui = true`
    const dep_sokol = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
        .wgpu = true,
        .with_sokol_imgui = true,
        .dynamic_linkage = true,
    });
    const dep_cimgui = b.dependency("cimgui", .{
        .target = target,
        .optimize = optimize,
        // With msvc ABI, shared DLLs don't auto-export symbols, so the
        // ig* cimgui functions wouldn't be visible to sokol_clib.dll.
        // Build as static to embed the symbols directly.
        .dynamic_linkage = builtin.os.tag != .windows or target.result.abi != .msvc,
    });
    const dep_zdt = b.dependency("zdt", opts);
    const dep_libraw = b.dependency("libraw", opts);
    // const dep_wgpu_native = b.dependency("wgpu_native_zig", opts);
    const dep_zdawn = b.dependency("zdawn", .{});
    const dep_zigimg = b.dependency("zigimg", opts);
    const dep_zbench = b.dependency("zbench", opts);
    const dep_zuballoc = b.dependency("zuballoc", opts);
    const dep_zr = b.dependency("zr", opts);

    // inject the cimgui header search path into the sokol C library compile step
    dep_sokol.artifact("sokol_clib").root_module.addIncludePath(dep_cimgui.path(cimgui_conf.include_dir));
    // inject the webgpu/webgpu.h headers from zdawn
    @import("zdawn").addDawnPaths(b, dep_sokol.artifact("sokol_clib").root_module, target.result);
    // When sokol_clib is built as a shared library, its native WebGPU symbols
    // must resolve against the same shared Dawn instance used by the rest of
    // the app. Link sokol_clib against shared zdawn instead of letting it rely
    // on the final exe link step.
    dep_sokol.artifact("sokol_clib").root_module.linkLibrary(dep_zdawn.artifact("zdawn"));
    dep_sokol.artifact("sokol_clib").root_module.linkLibrary(dep_cimgui.artifact(cimgui_conf.clib_name));
    dep_sokol.artifact("sokol_clib").root_module.addRPathSpecial("@loader_path");
    // Embed /ALTERNATENAME linker directives for CRT init stubs (same as zdawn).
    if (builtin.os.tag == .windows and target.result.abi == .msvc) {
        dep_sokol.artifact("sokol_clib").root_module.addCSourceFile(.{
            .file = dep_zdawn.path("src/crt_stubs.c"),
        });
    }
    // The standalone Windows SDK is missing individual x64 import libraries
    // (gdi32, shell32, imm32, etc.). We link OneCoreUAP.Lib (which has all
    // the actual symbols) AND add a directory of generated import libraries
    // to satisfy linkSystemLibrary("gdi32") etc. file lookups.
    if (builtin.os.tag == .windows) {
        const stub_dir: std.Build.LazyPath = .{
            .cwd_relative = b.pathJoin(&.{ b.pathFromRoot("."), ".scratch", "stublibs" }),
        };
        dep_sokol.artifact("sokol_clib").root_module.addLibraryPath(stub_dir);
        dep_sokol.artifact("sokol_clib").root_module.linkSystemLibrary("OneCoreUAP", .{});
        dep_libraw.artifact("libraw_clib").root_module.addLibraryPath(stub_dir);
        dep_libraw.artifact("libraw_clib").root_module.linkSystemLibrary("OneCoreUAP", .{});
    }
    // Install the shared runtime libs into this project's zig-out/lib so the
    // host exe and zr plugin can both load them from a single place.
    b.installArtifact(dep_zdawn.artifact("zdawn"));
    b.installArtifact(dep_sokol.artifact("sokol_clib"));
    if (dep_cimgui.artifact(cimgui_conf.clib_name).isDynamicLibrary()) {
        b.installArtifact(dep_cimgui.artifact(cimgui_conf.clib_name));
    }

    // OPTIONS
    const mod_options = b.addOptions();
    const build_date = std.Io.Timestamp.now(b.graph.io, std.Io.Clock.real).toSeconds();
    mod_options.addOption(i64, "timestamp", build_date);
    mod_options.addOption(bool, "docking", opt_docking);

    // Shaders (for UI)
    // https://github.com/floooh/pacman.zig/blob/main/build.zig
    // extract the sokol module and shdc dependency from sokol dependency
    const mod_sokol = dep_sokol.module("sokol");
    const dep_shdc = dep_sokol.builder.dependency("shdc", .{});
    const mod_texview_shd = try sokol.shdc.createModule(b, "texview_shader", mod_sokol, .{
        .shdc_dep = dep_shdc,
        .input = "src/gui/texview.glsl",
        .output = "texview.zig",
        .slang = .{ .wgsl = true },
    });

    // CONSOLE MODULE
    const mod_console = b.createModule(.{
        .root_source_file = b.path("src/cli/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{},
    });

    // PIE MODULE
    // main module with sokol and cimgui imports
    const mod_pie = b.createModule(.{
        .root_source_file = b.path("src/engine/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "console", .module = mod_console },
            .{ .name = "zdt", .module = dep_zdt.module("zdt") },
            .{ .name = "libraw", .module = dep_libraw.module("libraw") },
            .{ .name = "wgpu_dawn", .module = dep_zdawn.module("webgpu") },
            .{ .name = "zigimg", .module = dep_zigimg.module("zigimg") },
            .{ .name = "zuballoc", .module = dep_zuballoc.module("zuballoc") },
        },
    });
    mod_pie.linkLibrary(dep_zdawn.artifact("zdawn"));

    // GUI MODULE
    // main module with sokol and cimgui imports
    const mod_gui = b.createModule(.{
        .root_source_file = b.path("src/gui/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true, // Necessary for zr
        .imports = &.{
            .{ .name = "pie", .module = mod_pie },
            .{ .name = "libraw", .module = dep_libraw.module("libraw") },
            .{ .name = "wgpu_dawn", .module = dep_zdawn.module("webgpu") },
            .{ .name = cimgui_conf.module_name, .module = dep_cimgui.module(cimgui_conf.module_name) },
            .{ .name = "texview_shader", .module = mod_texview_shd },
            .{ .name = "sokol", .module = dep_sokol.module("sokol") },
            .{ .name = "zr", .module = dep_zr.module("zr") },
        },
    });

    // APP MODULE
    // main module with sokol and cimgui imports
    const mod_app = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pie", .module = mod_pie },
            .{ .name = "gui", .module = mod_gui },
            .{ .name = "console", .module = mod_console },
            // .{ .name = "texview_shader", .module = mod_texview_shd },
            .{ .name = "sokol", .module = dep_sokol.module("sokol") },
            // .{ .name = cimgui_conf.module_name, .module = dep_cimgui.module(cimgui_conf.module_name) },
            // .{ .name = "zdt", .module = dep_zdt.module("zdt") },
            // .{ .name = "libraw", .module = dep_libraw.module("libraw") },
            .{ .name = "wgpu_dawn", .module = dep_zdawn.module("webgpu") },
            .{ .name = "zr", .module = dep_zr.module("zr") },
        },
    });
    mod_app.addOptions("build_options", mod_options);

    // link gui for hot reload
    // if (optimize == .Debug) {
    const gui_dl = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "gui",
        .root_module = mod_gui,
    });
    // The hot-reload plugin lives in zig-out/lib and depends on sibling
    // shared libs (libzdawn.dylib, libsokol_clib.dylib, ...), so resolve
    // them relative to the plugin itself.
    gui_dl.root_module.addRPathSpecial("@loader_path");
    b.installArtifact(gui_dl);
    // }

    // TESTS
    // UNIT TESTS
    const test_step = b.step("test", "Run unit tests");
    const unit_tests = b.addTest(.{
        .name = "unit tests",
        .root_module = mod_app,
        .test_runner = .{ .path = b.path("testing/test_runner.zig"), .mode = .simple },
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);

    // INTEGRATION TESTS
    // first run the zig code as an executable
    const mod_integration = b.createModule(.{
        .root_source_file = b.path("testing/integration/integration.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            // .{ .name = "app", .module = mod_app },
            .{ .name = "pie", .module = mod_pie },
            .{ .name = "console", .module = mod_console },
            .{ .name = "libraw", .module = dep_libraw.module("libraw") },
            .{ .name = "zigimg", .module = dep_zigimg.module("zigimg") },
            .{ .name = "zbench", .module = dep_zbench.module("zbench") },
        },
    });
    const integration_test_step = b.step("integration", "Run integration tests");
    const integration_tests = b.addTest(.{
        .name = "integration tests",
        .root_module = mod_integration,
        .test_runner = .{ .path = b.path("testing/test_runner.zig"), .mode = .simple },
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);
    integration_test_step.dependOn(&run_integration_tests.step);

    // from here on different handling for native vs wasm builds
    if (target.result.cpu.arch.isWasm()) {
        try buildWasm(b, .{
            .mod_main = mod_app,
            .dep_sokol = dep_sokol,
            .dep_cimgui = dep_cimgui,
            .cimgui_clib_name = cimgui_conf.clib_name,
        });
    } else {
        try buildNative(b, mod_app, dep_zdawn, target.result);
    }
}

fn buildNative(b: *Build, mod: *Build.Module, dep_zdawn: *Build.Dependency, target_result: std.Target) !void {
    const exe = b.addExecutable(.{
        .name = "pie",
        .root_module = mod,
    });
    // Force Zig's own entry point (WinStartup) instead of MSVC's
    // mainCRTStartup, so the Zig runtime is properly initialized
    // before main() is called. MSVC's mainCRTStartup calls main()
    // with C-style (int argc, char** argv) parameters, but Zig's
    // main expects std.process.Init.
    exe.entry = .enabled;
    // Link zdawn's zdawn artifact (which now builds as a shared lib and
    // contains Dawn) plus any platform system deps.
    @import("zdawn").addLibraryPathsTo(exe);
    @import("zdawn").linkSystemDeps(b, exe);
    // Embed /ALTERNATENAME linker directives for CRT init stubs and
    // POSIX function name aliases (same as zdawn and sokol_clib).
    if (builtin.os.tag == .windows and target_result.abi == .msvc) {
        exe.root_module.addCSourceFile(.{
            .file = dep_zdawn.path("src/crt_stubs.c"),
        });
    }
    // The installed exe lives in zig-out/bin and loads its shared libs from
    // zig-out/lib.
    exe.root_module.addRPathSpecial("@loader_path/../lib");
    b.installArtifact(exe);
    // Dawn dynamically loads system DLLs at runtime via LoadLibraryExW with
    // LOAD_LIBRARY_SEARCH_DEFAULT_DIRS. This flag fails with Error 87 when
    // SetDefaultDllDirectories hasn't been called (the MSVC CRT normally
    // handles this, but our CRT init stubs are no-ops). As a workaround,
    // copy the needed DLLs to the exe directory where they're always found.
    if (builtin.os.tag == .windows) {
        const system_dlls = [_][]const u8{
            "d3dcompiler_47.dll",
            "vulkan-1.dll",
            "dxgi.dll",
            "d3d11.dll",
            "d3d12.dll",
        };
        for (system_dlls) |dll| {
            const src = b.fmt("C:\\Windows\\System32\\{s}", .{dll});
            const install_dll = b.addInstallBinFile(
                .{ .cwd_relative = src },
                dll,
            );
            exe.step.dependOn(&install_dll.step);
        }
    }
    const exe_step = b.step("run", "Run pie");
    // const run_cmd = b.addRunArtifact(exe);
    // run_cmd.step.dependOn(b.getInstallStep());
    // exe_step.dependOn(&run_cmd.step);

    const run_cmd = b.addSystemCommand(&.{b.getInstallPath(.bin, "pie")});
    run_cmd.step.dependOn(b.getInstallStep());
    exe_step.dependOn(&run_cmd.step);
}

const BuildWasmOptions = struct {
    mod_main: *Build.Module,
    dep_sokol: *Build.Dependency,
    dep_cimgui: *Build.Dependency,
    cimgui_clib_name: []const u8,
};

// https://github.com/floooh/sokol-zig-imgui-sample/blob/main/build.zig
fn buildWasm(b: *Build, opts: BuildWasmOptions) !void {
    // build the main file into a library, this is because the WASM 'exe'
    // needs to be linked in a separate build step with the Emscripten linker
    const demo = b.addLibrary(.{
        .name = "demo",
        .root_module = opts.mod_main,
    });

    // get the Emscripten SDK dependency from the sokol dependency
    const dep_emsdk = opts.dep_sokol.builder.dependency("emsdk", .{});

    // need to inject the Emscripten system header include path into
    // the cimgui C library otherwise the C/C++ code won't find
    // C stdlib headers
    const emsdk_incl_path = dep_emsdk.path("upstream/emscripten/cache/sysroot/include");
    opts.dep_cimgui.artifact(opts.cimgui_clib_name).root_module.addSystemIncludePath(emsdk_incl_path);

    // all C libraries need to depend on the sokol library, when building for
    // WASM this makes sure that the Emscripten SDK has been setup before
    // C compilation is attempted (since the sokol C library depends on the
    // Emscripten SDK setup step)
    opts.dep_cimgui.artifact(opts.cimgui_clib_name).step.dependOn(&opts.dep_sokol.artifact("sokol_clib").step);

    // create a build step which invokes the Emscripten linker
    const link_step = try sokol.emLinkStep(b, .{
        .lib_main = demo,
        .target = opts.mod_main.resolved_target.?,
        .optimize = opts.mod_main.optimize.?,
        .emsdk = dep_emsdk,
        .use_webgl2 = true,
        .use_emmalloc = true,
        .use_filesystem = false,
        .shell_file_path = b.path("src/web/shell.html"),
    });
    // attach to default target
    b.getInstallStep().dependOn(&link_step.step);
    // ...and a special run step to start the web build output via 'emrun'
    const run = sokol.emRunStep(b, .{ .name = "pie", .emsdk = dep_emsdk });
    run.step.dependOn(&link_step.step);
    b.step("run", "Run pie").dependOn(&run.step);
}
