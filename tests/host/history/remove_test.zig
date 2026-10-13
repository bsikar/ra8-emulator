const std = @import("std");
const history = @import("ra8").host.history;
const fixture = @import("root_test.zig");

test "host lifecycle rm rejects unmarked live bad targets and mismatched ids" {
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('d');
    defer _ = session.close(null, .stay) catch @panic("session cleanup failed");
    try std.testing.expectError(error.Locked, history.remove.discard(&f.cache, &session.id, &session.id));
    try std.testing.expectError(error.BadName, history.remove.entryRemove(&f.cache, "../outside", .{}));
    const other: history.name.Id = @splat('e');
    try std.testing.expectError(error.BadName, history.remove.discard(&f.cache, &session.id, &other));
    try f.cache.dir.createDir(fixture.io, &other, .default_dir);
    try std.testing.expectError(error.Unmarked, history.remove.discard(&f.cache, &other, &other));
    try f.cache.owns(&other);
}

test "host lifecycle automatic prune never removes kept but explicit rm may" {
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('e');
    const id = session.id;
    try session.keep();
    fixture.Fixture.abandon(&session);
    try std.testing.expectError(error.Kept, history.remove.entryRemove(&f.cache, &id, .{}));
    try history.remove.entryRemove(&f.cache, &id, .{ .allow_kept = true });
    try std.testing.expectError(error.NotFound, f.cache.owns(&id));
}

test "host lifecycle rm protects unmarked trash on a colliding trash name" {
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('f');
    const id = session.id;
    fixture.Fixture.abandon(&session);
    var buffer: history.name.Buffer = undefined;
    const trash = history.name.trash(&buffer, &id);
    try f.cache.dir.createDir(fixture.io, trash, .default_dir);
    try std.testing.expectError(error.TrashTaken, history.remove.discard(&f.cache, &id, &id));
    try f.cache.owns(&id);
    try f.cache.owns(trash);
}
