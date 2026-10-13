const std = @import("std");
const builtin = @import("builtin");
const h = @import("ra8").host.history;
const f = @import("../root_test.zig");
test "host move receipt refuses linked metadata without reading an outside object" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var fixture = try f.Fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.writeFile(f.io, .{ .sub_path = "sentinel", .data = "preserve" });
    try fixture.hardLink("sentinel", fixture.cache.dir, "moving");
    try std.testing.expectError(error.OutsideRoot, h.move.receipt.read(f.allocator, f.io, fixture.cache.dir, "moving"));
    var bytes: [32]u8 = undefined;
    try std.testing.expectEqualStrings("preserve", try fixture.tmp.dir.readFile(f.io, "sentinel", &bytes));
}
