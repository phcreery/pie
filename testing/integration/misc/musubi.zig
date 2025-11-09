const std = @import("std");

const pie = @import("pie");

test "musubi" {
    const eql = std.meta.eql;

    const Pool = @import("zpool").Pool;
    const allocator = std.testing.allocator;

    const Image = struct {
        data: []u8,
    };
    const ImageInfoType = struct {
        width: u32,
        height: u32,
        format: u32,
    };

    // const ImagePtr = Image;
    // const ImageInfo = ImageInfoType;

    const ImagePool = Pool(16, 16, Image, struct {
        ptr: Image,
        info: ImageInfoType,
    });
    const ImageHandle = ImagePool.Handle;

    var imagePool = ImagePool.initCapacity(allocator, 100) catch unreachable;
    defer imagePool.deinit();

    const Musubi = pie.musubi.Musubi;

    // const VertexId = []const u8;
    // const EdgeId = []const u8;

    // const VertexId = pie.engine.api.ModuleDesc;
    const VertexId = ImageHandle;
    const EdgeId = []const u8;

    const Graph = Musubi(VertexId, EdgeId, void, .directed, .unweighted);
    var graph: Graph = .{};
    graph.init(std.testing.allocator);
    defer graph.deinit();

    const data = allocator.alloc(u8, 1 * 1 * 4) catch unreachable;
    defer allocator.free(data);
    const ptr: Image = .{
        .data = data,
    };
    const info: ImageInfoType = .{
        .width = 1,
        .height = 1,
        .format = 4,
    };
    const handle: ImageHandle = try imagePool.add(.{
        .ptr = ptr,
        .info = info,
    });

    // Inserts and stats
    const lax = try graph.insertVertex(handle);
    // const sfo = try graph.insertVertex("SFO");
    try std.testing.expect(eql(lax.id, handle));
    // try std.testing.expect(eql(sfo.id, "SFO"));
    // try std.testing.expect(graph.vertexCount() == 2);
    // try std.testing.expect(graph.edgeCount() == 0);

    var tree = graph.traverseTree(lax, .ino) catch unreachable;
    defer tree.deinit(allocator);
    for (tree.items) |v| {
        std.log.info("Visited vertex: {any}", .{v.id});
    }
}
