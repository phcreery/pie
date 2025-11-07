const std = @import("std");

test "musubi" {
    if (true) {
        return error.SkipZigTest;
    }
    const Musubi = @import("musubi.zig").Musubi;
    var musubi = Musubi.init();
    defer musubi.deinit();

    musubi.run();
}
