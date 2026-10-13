const std = @import("std");
const history = @import("ra8").host.history;
const fixture = @import("root_test.zig");

test "host lifecycle path capabilities reserve top markers and require real directories" {
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('7');
    try std.testing.expectError(error.Reserved, history.paths.leaf(.top, "kept"));
    try std.testing.expectEqualStrings("root.bin", try history.paths.leaf(.top, "root.bin"));
    {
        var objects = try session.dir.openDir(fixture.io, "objects", .{});
        defer objects.close(fixture.io);
        for ([_][]const u8{ history.move.receipt.origin, history.move.receipt.ready }) |leaf| {
            objects.deleteFile(fixture.io, leaf) catch |err| if (err != error.FileNotFound) return err;
        }
    }
    try session.dir.deleteDir(fixture.io, "objects");
    try session.dir.writeFile(fixture.io, .{ .sub_path = "objects", .data = "wrong kind" });
    try std.testing.expectError(error.OutsideRoot, history.paths.area(&session, .objects));
    try std.testing.expectEqual(history.session.Outcome.deleted, try session.close(null, .stay));
}
