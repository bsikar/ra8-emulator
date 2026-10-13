const std = @import("std");
const history = @import("ra8").host.history;
const fixture = @import("../root_test.zig");

test "native lifecycle dispatch preserves an existing foreign empty destination" {
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('f');
    defer fixture.Fixture.abandon(&session);
    try f.cache.dir.createDir(fixture.io, "foreign", .default_dir);
    const before = try f.cache.dir.statFile(fixture.io, "foreign", .{});
    var gate = try f.cache.gate(.exclusive);
    defer gate.release();
    try std.testing.expectError(error.PathAlreadyExists, history.move.dispatch.directory(.{ .source = &f.cache, .target = &f.cache, .authorities = &.{ gate.file, session.lock } }, &session.id, "foreign", "publish\n", null));
    const after = try f.cache.dir.statFile(fixture.io, "foreign", .{});
    try std.testing.expectEqual(before.inode, after.inode);
    var dir = try f.cache.dir.openDir(fixture.io, "foreign", .{ .iterate = true });
    defer dir.close(fixture.io);
    var entries = dir.iterate();
    try std.testing.expect((try entries.next(fixture.io)) == null);
}
