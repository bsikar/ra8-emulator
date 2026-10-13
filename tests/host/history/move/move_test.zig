const std = @import("std");
const history = @import("ra8").host.history;
const fixture = @import("../root_test.zig");

test "host lifecycle non-overwriting move validates names and preserves a collision" {
    var f = try fixture.Fixture.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(fixture.io, .{ .sub_path = "source", .data = "original" });
    try f.tmp.dir.writeFile(fixture.io, .{ .sub_path = "target", .data = "preserved" });
    try std.testing.expectError(error.PathAlreadyExists, portable(fixture.io, f.tmp.dir, "source", f.tmp.dir, "target"));
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("preserved", try f.tmp.dir.readFile(fixture.io, "target", &buffer));
    try std.testing.expectError(error.BadName, portable(fixture.io, f.tmp.dir, "../source", f.tmp.dir, "other"));
    // A mount with no native move that refuses to replace has nothing more
    // to show here; move/tree_test.zig covers what is used there instead.
    try portable(fixture.io, f.tmp.dir, "source", f.tmp.dir, "other");
    try std.testing.expectEqualStrings("original", try f.tmp.dir.readFile(fixture.io, "other", &buffer));
}

fn portable(io: std.Io, a: std.Io.Dir, from: []const u8, b: std.Io.Dir, to: []const u8) !void {
    history.move.preserve(io, a, from, b, to) catch |err| switch (err) {
        error.OperationUnsupported => return history.move.file.carry(a, from, b, to),
        else => return err,
    };
}
