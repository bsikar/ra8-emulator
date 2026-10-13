const std = @import("std");
const history = @import("ra8").host.history;
const fixture = @import("root_test.zig");

test "host lifecycle scratch and frames disappear on close while their handles remain usable" {
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('3');
    for ([_]history.scratch.Area{ .scratch, .frames }) |area| {
        const file = try history.scratch.open(&session, area, "cache-1");
        try file.writePositionalAll(fixture.io, "temporary", 0);
        var buffer: [9]u8 = undefined;
        try std.testing.expectEqual(@as(usize, 9), try file.readPositionalAll(fixture.io, &buffer, 0));
        try std.testing.expectEqualStrings("temporary", &buffer);
        file.close(fixture.io);
        var dir = try session.dir.openDir(fixture.io, @tagName(area), .{});
        try std.testing.expectError(error.FileNotFound, dir.access(fixture.io, "cache-1", .{}));
        dir.close(fixture.io);
    }
    try std.testing.expectError(error.BadName, history.scratch.open(&session, .scratch, "../escape"));
    try std.testing.expectEqual(history.session.Outcome.deleted, try session.close(null, .stay));
}
