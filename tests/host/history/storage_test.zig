const std = @import("std");
const history = @import("ra8").host.history;
const fixture = @import("root_test.zig");

test "host lifecycle injected byte store supports exact offsets sync truncate rename and listing" {
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('1');
    const store = history.storage.Store.from(&session);
    const file = try store.vtable.open(store.context, .log, "events-0", .create);
    try file.vtable.write(file.context, 0, "abcdef");
    try file.vtable.write(file.context, 2, "XY");
    try file.vtable.sync(file.context);
    var buffer: [6]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 6), try file.vtable.read(file.context, 0, &buffer));
    try std.testing.expectEqualStrings("abXYef", &buffer);
    try file.vtable.truncate(file.context, 4);
    try std.testing.expectEqual(@as(u64, 4), try file.vtable.length(file.context));
    file.vtable.close(file.context);
    try store.vtable.rename(store.context, .log, "events-0", "events-1");
    var seen: u64 = 0;
    const callback = struct {
        fn visit(context: *anyopaque, text: []const u8, size: u64) !void {
            const counter: *u64 = @ptrCast(@alignCast(context));
            try std.testing.expectEqualStrings("events-1", text);
            try std.testing.expectEqual(@as(u64, 4), size);
            counter.* += 1;
        }
    };
    try store.vtable.list(store.context, .log, .{ .context = &seen, .visit = callback.visit });
    try std.testing.expectEqual(@as(u64, 1), seen);
    try store.vtable.remove(store.context, .log, "events-1");
    try std.testing.expectEqual(history.session.Outcome.deleted, try session.close(null, .stay));
}

test "host lifecycle injected store refuses marker mutation traversal and replacement" {
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('2');
    defer _ = session.close(null, .stay) catch @panic("session cleanup failed");
    const store = history.storage.Store.from(&session);
    try std.testing.expectError(error.Reserved, store.vtable.open(store.context, .top, "owner.lock", .create));
    try std.testing.expectError(error.BadName, store.vtable.open(store.context, .objects, "../owner", .read));
    const first = try store.vtable.open(store.context, .objects, "hash1", .create);
    first.vtable.close(first.context);
    const second = try store.vtable.open(store.context, .objects, "hash2", .create);
    second.vtable.close(second.context);
    try std.testing.expectError(error.PathAlreadyExists, store.vtable.rename(store.context, .objects, "hash1", "hash2"));
    try std.testing.expectError(error.PathAlreadyExists, store.vtable.open(store.context, .objects, "hash1", .create));
    try std.testing.expectError(error.EphemeralOnly, store.vtable.open(store.context, .frames, "frame1", .read));
}
