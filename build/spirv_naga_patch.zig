//! Post-processes SPIR-V emitted by the Zig compiler so that naga (wgpu's
//! SPIR-V front-end) can parse it. Run as: `spirv_naga_patch <in.spv> <out.spv>`.
//!
//! Current Zig master emits two things naga cannot handle (both legal SPIR-V,
//! they are limitations/bugs on the consumer side):
//!
//!   1. `OpCapability Linkage` — Vulkan forbids it (only valid pre-link), and
//!      strict validators reject the module.
//!   2. `Aligned` memory operands on `OpLoad`/`OpStore` (e.g.
//!      `%v = OpLoad %u32 %p Aligned 4`). naga's SPIR-V front-end does not
//!      implement memory operands on loads/stores and fails with
//!      "invalid operand count N for Load".
//!
//! Both are optional metadata, so we can simply strip them. Removing words
//! never invalidates the `Bound` header field (it only shrinks).
//!
//! Note: SPIR-V words are little-endian on disk; this tool assumes a
//! little-endian host (fine for x86_64/aarch64 macOS+Linux dev machines).
const std = @import("std");

const OP_CAPABILITY = 17;
const OP_COPY_MEMORY = 37;
const OP_LOAD = 61;
const OP_STORE = 62;

const CAP_LINKAGE = 5;
const MEM_OPERAND_ALIGNED = 0x2;

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
    defer it.deinit();
    const argv0 = it.next() orelse "spirv-naga-patch";
    const in_path = it.next() orelse {
        std.debug.print("usage: {s} <in.spv> <out.spv>\n", .{argv0});
        std.process.exit(1);
    };
    const out_path = it.next() orelse {
        std.debug.print("usage: {s} <in.spv> <out.spv>\n", .{argv0});
        std.process.exit(1);
    };

    const bytes = try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), init.io, in_path, alloc, .limited(64 * 1024 * 1024));
    if (bytes.len % @sizeOf(u32) != 0) return error.InvalidSpirvLength;

    // Copy into a u32-aligned buffer (see: the same reason gpu.zig does this).
    const words = try alloc.alloc(u32, bytes.len / @sizeOf(u32));
    @memcpy(std.mem.sliceAsBytes(words), bytes);

    if (words.len < 5 or words[0] != 0x07230203) return error.BadMagic;
    if (words[4] != 0) return error.SpvSchemaMustBeZero; // header: magic, version, generator, bound, schema

    var r: usize = 5; // read index (past the 5-word header)
    var w: usize = 5; // write index; invariant: w <= r
    var dropped_caps: usize = 0;
    var stripped_aligned: usize = 0;

    while (r < words.len) {
        const op = words[r] & 0xFFFF;
        const count = words[r] >> 16;
        if (count == 0 or r + count > words.len) return error.MalformedInstruction;

        var shrink: usize = 0;
        switch (op) {
            OP_CAPABILITY => if (words[r + 1] == CAP_LINKAGE) {
                // Drop the whole instruction.
                r += count;
                dropped_caps += 1;
                continue;
            },
            // ... base operands, then [mask, alignment] if `Aligned` is set.
            OP_LOAD => if (count == 6 and words[r + 4] == MEM_OPERAND_ALIGNED) {
                shrink = 2;
                stripped_aligned += 1;
            },
            OP_STORE => if (count == 5 and words[r + 3] == MEM_OPERAND_ALIGNED) {
                shrink = 2;
                stripped_aligned += 1;
            },
            OP_COPY_MEMORY => if (count == 5 and words[r + 3] == MEM_OPERAND_ALIGNED) {
                shrink = 2;
                stripped_aligned += 1;
            },
            else => {},
        }

        const new_count: u32 = @intCast(count - shrink);
        words[r] = (new_count << 16) | op;
        if (w != r) {
            std.mem.copyForwards(u32, words[w .. w + new_count], words[r .. r + new_count]);
        }
        w += new_count;
        r += count;
    }

    const out_bytes = std.mem.sliceAsBytes(words[0..w]);
    try std.Io.Dir.writeFile(std.Io.Dir.cwd(), init.io, .{ .sub_path = out_path, .data = out_bytes });

    std.debug.print("spirv-naga-patch: {s} -> {s} ({d} bytes, dropped {d} Linkage capability, stripped {d} Aligned operand(s))\n", .{
        in_path, out_path, out_bytes.len, dropped_caps, stripped_aligned,
    });
}