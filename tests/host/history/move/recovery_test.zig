const std = @import("std");
const history = @import("ra8").host.history;
const fixture = @import("../root_test.zig");

test "partial native anchor protects reopen removal and ID reuse" {
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('e');
    const id = session.id;
    try session.dir.writeFile(fixture.io, .{ .sub_path = "log/events", .data = "protected bytes" });
    var buffer: history.name.Buffer = undefined;
    const anchor = try history.move.intent.leaf(&buffer, &id);
    try f.cache.dir.writeFile(fixture.io, .{ .sub_path = anchor, .data = "{" });
    fixture.Fixture.abandon(&session);
    try std.testing.expectError(error.Moving, history.session.Session.reopen(&f.cache, id));
    try std.testing.expectError(error.Moving, history.remove.entryRemove(&f.cache, &id, .{}));
    try std.testing.expectError(error.IdTaken, history.session.Session.create(&f.cache, .{ .id = id }));
    const report = try f.cache.recoverReport(null);
    try std.testing.expectEqual(@as(u64, 1), report.counts[@backingInt(history.recover.Status.unmarked)]);
    var bytes: [64]u8 = undefined;
    try std.testing.expectEqualStrings("{", try f.cache.dir.readFile(fixture.io, anchor, &bytes));
    var dir = try f.cache.dir.openDir(fixture.io, &id, .{});
    defer dir.close(fixture.io);
    try std.testing.expectEqualStrings("protected bytes", try dir.readFile(fixture.io, "log/events", &bytes));
}
