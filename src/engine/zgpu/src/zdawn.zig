// zgpu dawn linker shim.
//
// This module exists only so that the `zdawn` static-library artifact has at
// least one object file to archive (Zig 0.16 refuses to produce an archive
// with zero objects). All real code lives in the prebuilt libwebgpu_dawn.a
// that is linked via `root_module.linkSystemLibrary("webgpu_dawn", .{})`.
comptime {}
