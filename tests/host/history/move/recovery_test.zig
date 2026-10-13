const std = @import("std");
const builtin = @import("builtin");
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

fn seed(f: *fixture.Fixture, session: *history.session.Session, committed: bool) !void {
    var gate = try f.cache.gate(.exclusive);
    defer gate.release();
    const context: history.move.context.Context = .{ .source = &f.cache, .target = &f.cache, .authorities = &.{ gate.file, session.lock } };
    var buffer: history.name.Buffer = undefined;
    const parsed = try history.move.intent.start(fixture.allocator, context, &session.id, history.name.trash(&buffer, &session.id), history.layout.moves.trash);
    defer parsed.deinit();
    if (committed) try history.move.intent.commit(context, parsed.value);
}

test "plain Base open retires a pre-COMMIT crash without replaying the move" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('e');
    const id = session.id;
    try session.dir.writeFile(fixture.io, .{ .sub_path = "log/events", .data = "cancelled payload" });
    const original = try history.move.file.state(f.cache.dir, &id);
    try seed(&f, &session, false);
    fixture.Fixture.abandon(&session);
    var plain = try history.base.Base.open(fixture.allocator, fixture.io, f.cache.path, .cache);
    defer plain.close();
    try std.testing.expect(!history.move.intent.pending(fixture.io, plain.dir, &id));
    try std.testing.expect(original.same(try history.move.file.state(plain.dir, &id)));
    var buffer: history.name.Buffer = undefined;
    try std.testing.expectError(error.FileNotFound, plain.dir.access(fixture.io, history.name.trash(&buffer, &id), .{}));
    var reopened = try history.session.Session.reopen(&plain, id);
    try std.testing.expectError(error.FileNotFound, reopened.dir.access(fixture.io, history.move.intent.note, .{}));
    var bytes: [64]u8 = undefined;
    try std.testing.expectEqualStrings("cancelled payload", try reopened.dir.readFile(fixture.io, "log/events", &bytes));
    fixture.Fixture.abandon(&reopened);
    try history.remove.entryRemove(&plain, &id, .{});
    var reused = try history.session.Session.create(&plain, .{ .id = id });
    fixture.Fixture.abandon(&reused);
}

test "plain Base open preserves COMMIT authority and reports a distinct unknown" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('e');
    const id = session.id;
    try seed(&f, &session, true);
    fixture.Fixture.abandon(&session);
    var plain = try history.base.Base.open(fixture.allocator, fixture.io, f.cache.path, .cache);
    defer plain.close();
    try std.testing.expectError(error.NativeMoveUnknown, history.move.recovery.root(&plain, &id));
    var buffer: history.name.Buffer = undefined;
    const parsed = try history.move.intent.read(fixture.allocator, fixture.io, plain.dir, try history.move.intent.leaf(&buffer, &id), true);
    defer parsed.deinit();
    try std.testing.expect(parsed.value.committed);
    try std.testing.expect(!parsed.value.cancelled);
    try std.testing.expectError(error.Moving, history.session.Session.reopen(&plain, id));
    try std.testing.expectError(error.Moving, history.remove.entryRemove(&plain, &id, .{}));
    try std.testing.expectError(error.IdTaken, history.session.Session.create(&plain, .{ .id = id }));
    var source = try plain.dir.openDir(fixture.io, &id, .{});
    defer source.close(fixture.io);
    try source.access(fixture.io, history.move.intent.note, .{});
    try std.testing.expectError(error.FileNotFound, plain.dir.access(fixture.io, history.name.trash(&buffer, &id), .{}));
}

test "pre-COMMIT keep recovery leaves the source lease and retires only the empty target claim" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('e');
    const id = session.id;
    {
        var gates = try history.gates.Pair.acquire(&f.cache, &f.kept);
        defer gates.release();
        const lease = try history.lock.create(fixture.io, f.kept.dir, &id);
        defer lease.close(fixture.io);
        const context: history.move.context.Context = .{ .source = &f.cache, .target = &f.kept, .authorities = &.{ gates.first.file, gates.second.?.file, session.lock, lease } };
        const purpose = try std.fmt.allocPrint(fixture.allocator, history.layout.moves.keep ++ "{s}\n", .{f.kept.path});
        defer fixture.allocator.free(purpose);
        const parsed = try history.move.intent.start(fixture.allocator, context, &id, &id, purpose);
        parsed.deinit();
    }
    fixture.Fixture.abandon(&session);
    var plain = try history.base.Base.open(fixture.allocator, fixture.io, f.cache.path, .cache);
    defer plain.close();
    try std.testing.expect(!history.move.intent.pending(fixture.io, plain.dir, &id));
    var buffer: history.name.Buffer = undefined;
    try plain.dir.access(fixture.io, history.name.lease(&buffer, &id), .{});
    try std.testing.expectError(error.FileNotFound, f.kept.dir.access(fixture.io, history.name.lease(&buffer, &id), .{}));
    try std.testing.expectError(error.FileNotFound, f.kept.dir.access(fixture.io, &id, .{}));
    var reopened = try history.session.Session.reopen(&plain, id);
    fixture.Fixture.abandon(&reopened);
    try history.remove.entryRemove(&plain, &id, .{});
    var reused = try history.session.Session.create(&plain, .{ .id = id });
    fixture.Fixture.abandon(&reused);
}

test "pre-COMMIT keep cancellation preserves a colliding pointer and its lease" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('e');
    const id = session.id;
    {
        var gates = try history.gates.Pair.acquire(&f.cache, &f.kept);
        defer gates.release();
        const lease = try history.lock.create(fixture.io, f.kept.dir, &id);
        defer lease.close(fixture.io);
        var buffer: history.name.Buffer = undefined;
        try f.kept.dir.writeFile(fixture.io, .{ .sub_path = history.name.pointer(&buffer, &id), .data = "existing pointer bytes" });
        const context: history.move.context.Context = .{ .source = &f.cache, .target = &f.kept, .authorities = &.{ gates.first.file, gates.second.?.file, session.lock, lease } };
        const purpose = try std.fmt.allocPrint(fixture.allocator, history.layout.moves.keep ++ "{s}\n", .{f.kept.path});
        defer fixture.allocator.free(purpose);
        const parsed = try history.move.intent.start(fixture.allocator, context, &id, &id, purpose);
        parsed.deinit();
    }
    fixture.Fixture.abandon(&session);
    try history.move.recovery.root(&f.cache, &id);
    try std.testing.expect(!history.move.intent.pending(fixture.io, f.cache.dir, &id));
    var buffer: history.name.Buffer = undefined;
    try f.kept.dir.access(fixture.io, history.name.lease(&buffer, &id), .{});
    var bytes: [64]u8 = undefined;
    try std.testing.expectEqualStrings("existing pointer bytes", try f.kept.dir.readFile(fixture.io, history.name.pointer(&buffer, &id), &bytes));
    try f.cache.dir.access(fixture.io, &id, .{});
}

test "unflagged cancellation cannot clean a replacement source" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('e');
    const id = session.id;
    try seed(&f, &session, false);
    fixture.Fixture.abandon(&session);
    try f.cache.dir.rename(&id, f.cache.dir, "saved-source", fixture.io);
    try f.cache.dir.createDir(fixture.io, &id, .default_dir);
    var replacement = try f.cache.dir.openDir(fixture.io, &id, .{});
    defer replacement.close(fixture.io);
    try replacement.writeFile(fixture.io, .{ .sub_path = "foreign", .data = "replacement bytes" });
    try std.testing.expectError(error.IdentityConflict, history.move.recovery.root(&f.cache, &id));
    try std.testing.expect(history.move.intent.pending(fixture.io, f.cache.dir, &id));
    var original = try f.cache.dir.openDir(fixture.io, "saved-source", .{});
    defer original.close(fixture.io);
    try original.access(fixture.io, history.move.intent.note, .{});
    var bytes: [64]u8 = undefined;
    try std.testing.expectEqualStrings("replacement bytes", try replacement.readFile(fixture.io, "foreign", &bytes));
}
