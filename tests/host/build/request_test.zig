const std = @import("std");
const request = @import("ra8").host.build.request;

test "build recipes cannot override backend paths or inject shell commands" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const good = try request.parse(allocator, .{ .step = "install", .options = "[\"-Dtarget=thumb-freestanding-eabi\",\"-Dname=with spaces\"]", .artifact = "bin/fw.elf", .timeout_ms = 1000 });
    try std.testing.expectEqual(@as(usize, 2), good.options.len);
    for ([_][]const u8{ "[\"--prefix=/elsewhere\"]", "[\"-j99\"]", "{}", "[1]" }) |options| {
        try std.testing.expectError(error.InvalidRecipe, request.parse(allocator, .{ .step = "", .options = options, .artifact = "", .timeout_ms = 1000 }));
    }
    for ([_][]const u8{ "-h", "build;echo", "x/y" }) |step| {
        try std.testing.expectError(error.InvalidRecipe, request.parse(allocator, .{ .step = step, .options = "[]", .artifact = "", .timeout_ms = 1000 }));
    }
    try std.testing.expectError(error.InvalidPath, request.parse(allocator, .{ .step = "", .options = "[]", .artifact = "../old.elf", .timeout_ms = 1000 }));
}
