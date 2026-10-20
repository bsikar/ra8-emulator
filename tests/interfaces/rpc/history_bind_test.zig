//! Tests for src/interfaces/rpc/history_bind.zig (RA8EMU-1196): the
//! application-side bridge serves the recorder's log storage and object
//! space over a host history session, and close deletes the session.
const std = @import("std");
const ra8 = @import("ra8");
const history = ra8.host.history;

const bind_mod = ra8.rpc.history_bind;

test "an explicit cap sizes the bind's budget and scales its pieces" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    const cap = history.budget.bytes.floor;
    const plain = try bind_mod.Bind.open(gpa, std.testing.io, root, .{});
    const plain_floor = plain.disk.?.floor;
    _ = plain.close() catch {};
    const bind = try bind_mod.Bind.open(gpa, std.testing.io, root, .{ .cap = cap });
    defer _ = bind.close() catch {};
    try std.testing.expectEqual(cap, bind.disk.?.cap);
    try std.testing.expectEqual(cap * 60 / 100, bind.checkpoint_cap);
    try std.testing.expectEqual(plain_floor, bind.disk.?.floor);
}

test "a cap below the minimum share refuses the open" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    try std.testing.expectError(error.BudgetTooSmall, bind_mod.Bind.open(gpa, std.testing.io, root, .{ .cap = 1024 }));
}

test "the bind appends the log, puts objects and deletes its session on close" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    const bind = try bind_mod.Bind.open(gpa, std.testing.io, root, .{});
    try bind.storage.append(bind.storage.context, "hello");
    try bind.storage.append(bind.storage.context, "world");
    try bind.storage.flush(bind.storage.context);
    try std.testing.expectEqual(@as(u64, 10), try bind.logLength());
    try bind.storage.truncate(bind.storage.context, 5);
    try bind.storage.append(bind.storage.context, "!");
    try std.testing.expectEqual(@as(u64, 6), try bind.logLength());
    try bind.objects.put(bind.objects.context, "0123456789abcdef", "object bytes");
    try bind.objects.put(bind.objects.context, "0123456789abcdef", "object bytes");
    const store = history.storage.Store.from(&bind.session);
    const log = try store.vtable.open(store.context, .log, "events-0", .read);
    var log_bytes: [6]u8 = undefined;
    const seen = try log.vtable.read(log.context, 0, &log_bytes);
    log.vtable.close(log.context);
    try std.testing.expectEqual(@as(usize, 6), seen);
    try std.testing.expectEqualStrings("hello!", &log_bytes);
    const object = try store.vtable.open(store.context, .objects, "0123456789abcdef", .read);
    var object_bytes: [12]u8 = undefined;
    const held = try object.vtable.read(object.context, 0, &object_bytes);
    object.vtable.close(object.context);
    try std.testing.expectEqual(@as(usize, 12), held);
    try std.testing.expectEqualStrings("object bytes", &object_bytes);
    try std.testing.expect(bind.disk != null);
    try std.testing.expect(bind.disk.?.cap > 0);
    try std.testing.expect(bind.disk.?.floor > 0);
    try std.testing.expect(try bind.disk.?.free(bind.disk.?.context) > 0);
    try std.testing.expectEqual(history.session.Outcome.deleted, try bind.close());
}
