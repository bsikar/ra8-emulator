const std = @import("std");
const history = @import("ra8").host.history;
const fixture = @import("root_test.zig");

test "host lifecycle listing reports remote ownership without authorizing deletion" {
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('4');
    try session.dir.deleteFile(fixture.io, history.layout.files.owner);
    try history.owner.write(fixture.io, session.dir, .{ .host = "remote-fixture", .pid = 42 });
    fixture.Fixture.abandon(&session);
    var entries = try history.catalog.Iterator.init(&f.cache);
    const entry = (try entries.next()).?;
    try std.testing.expectEqual(history.catalog.Status.other_host, entry.status);
    try std.testing.expectEqualStrings("remote-fixture", entry.owner.?.host);
    try std.testing.expectEqual(@as(u64, 42), entry.owner.?.pid);
    try std.testing.expectEqual(history.lock.State.free, entry.lock);
    try std.testing.expect((try entries.next()) == null);
    try std.testing.expectError(error.OtherHost, history.remove.entryRemove(&f.cache, &session.id, .{}));
}

test "host lifecycle du reports added logical payload and ignores lifecycle markers in listing" {
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('5');
    const before = try history.catalog.du(&f.cache, &session.id);
    try session.dir.writeFile(fixture.io, .{ .sub_path = "root.bin", .data = "123456789" });
    const after = try history.catalog.du(&f.cache, &session.id);
    try std.testing.expectEqual(before + 9, after);
    try std.testing.expectEqual(history.session.Outcome.deleted, try session.close(null, .stay));
    var entries = try history.catalog.Iterator.init(&f.cache);
    try std.testing.expect((try entries.next()) == null);
}
