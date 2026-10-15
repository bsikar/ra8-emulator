const std = @import("std");
const builtin = @import("builtin");
const history = @import("ra8").host.history;
const fixture = @import("../root_test.zig");

test "bound proof reads the pinned anchor and note and refuses missing or linked names" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('b');
    defer fixture.Fixture.abandon(&session);
    var gate = try f.cache.gate(.exclusive);
    defer gate.release();
    const context: history.move.context.Context = .{ .source = &f.cache, .target = &f.cache, .authorities = &.{ gate.file, session.lock } };
    var target_buffer: history.name.Buffer = undefined;
    const target = history.name.trash(&target_buffer, &session.id);
    const started = try history.move.intent.start(fixture.allocator, context, &session.id, target, history.layout.moves.trash);
    defer started.deinit();
    const good = try history.move.intent.boundProof(fixture.allocator, fixture.io, f.cache.dir, session.dir, &session.id);
    defer good.deinit();
    try std.testing.expectEqualStrings(&started.value.nonce, &good.record.value.nonce);
    var anchor_buffer: history.name.Buffer = undefined;
    const anchor = try history.move.intent.leaf(&anchor_buffer, &session.id);
    try history.move.file.link(f.cache.dir, anchor, f.cache.dir, "anchor-alias");
    try std.testing.expectError(error.OutsideRoot, history.move.intent.boundProof(fixture.allocator, fixture.io, f.cache.dir, session.dir, &session.id));
    try f.cache.dir.deleteFile(fixture.io, "anchor-alias");
    try history.move.file.link(session.dir, history.move.intent.note, session.dir, "note-alias");
    try std.testing.expectError(error.OutsideRoot, history.move.intent.boundProof(fixture.allocator, fixture.io, f.cache.dir, session.dir, &session.id));
    try session.dir.deleteFile(fixture.io, "note-alias");
    try std.testing.expectError(error.FileNotFound, history.move.intent.boundProof(fixture.allocator, fixture.io, f.kept.dir, session.dir, &session.id));
    try std.testing.expectError(error.FileNotFound, history.move.intent.boundProof(fixture.allocator, fixture.io, f.cache.dir, f.kept.dir, &session.id));
    const held = try history.metadata.open(fixture.io, f.cache.dir, anchor, .read_write);
    defer held.close(fixture.io);
    try held.writePositionalAll(fixture.io, "\nCOMMIT\n\nCANCEL\n", (try held.stat(fixture.io)).size);
    try std.testing.expectError(error.NativeMoveCancelled, history.move.intent.boundProof(fixture.allocator, fixture.io, f.cache.dir, session.dir, &session.id));
}

test "a proof taken before COMMIT is stale after it, and a forged note proves nothing" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('b');
    defer fixture.Fixture.abandon(&session);
    var gate = try f.cache.gate(.exclusive);
    defer gate.release();
    const context: history.move.context.Context = .{ .source = &f.cache, .target = &f.cache, .authorities = &.{ gate.file, session.lock } };
    var target_buffer: history.name.Buffer = undefined;
    const target = history.name.trash(&target_buffer, &session.id);
    const started = try history.move.intent.start(fixture.allocator, context, &session.id, target, history.layout.moves.trash);
    defer started.deinit();
    const before = try history.move.intent.boundProof(fixture.allocator, fixture.io, f.cache.dir, session.dir, &session.id);
    defer before.deinit();
    try history.move.intent.commit(context, started.value);
    const after = try history.move.intent.boundProof(fixture.allocator, fixture.io, f.cache.dir, session.dir, &session.id);
    defer after.deinit();
    try std.testing.expectEqualStrings(&before.digest.note, &after.digest.note);
    try std.testing.expect(!std.meta.eql(before.digest, after.digest));
    // A note rewritten to other bytes no longer matches the anchor's line.
    const note = try history.metadata.open(fixture.io, session.dir, history.move.intent.note, .read_write);
    defer note.close(fixture.io);
    try note.writePositionalAll(fixture.io, "[", 0);
    try std.testing.expectError(error.IdentityConflict, history.move.intent.boundProof(fixture.allocator, fixture.io, f.cache.dir, session.dir, &session.id));
}

test "native intent binds nonce and roots and cleans only its two recorded markers" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('b');
    defer fixture.Fixture.abandon(&session);
    try session.dir.writeFile(fixture.io, .{ .sub_path = "log/events", .data = "intent payload" });
    var gate = try f.cache.gate(.exclusive);
    defer gate.release();
    const context: history.move.context.Context = .{ .source = &f.cache, .target = &f.cache, .authorities = &.{ gate.file, session.lock } };
    try std.testing.expectError(error.BadReceipt, history.move.intent.start(fixture.allocator, context, &session.id, "foreign", history.layout.moves.publish));
    try std.testing.expect(!history.move.intent.pending(fixture.io, f.cache.dir, &session.id));
    var target_buffer: history.name.Buffer = undefined;
    const target = history.name.trash(&target_buffer, &session.id);
    const parsed = try history.move.intent.start(fixture.allocator, context, &session.id, target, history.layout.moves.trash);
    defer parsed.deinit();
    try history.move.intent.scope(context, parsed.value, &session.id, target);
    var changed = parsed.value;
    changed.nonce = @splat('c');
    try std.testing.expectError(error.IdentityConflict, history.move.intent.scope(context, changed, &session.id, target));
    changed = parsed.value;
    changed.to = "foreign";
    try std.testing.expectError(error.BadReceipt, history.move.intent.scope(context, changed, &session.id, "foreign"));
    try std.testing.expect(history.move.intent.pending(fixture.io, f.cache.dir, &session.id));
    var buffer: history.name.Buffer = undefined;
    const anchor = try history.move.intent.leaf(&buffer, &session.id);
    try history.move.file.link(f.cache.dir, anchor, f.cache.dir, "anchor-alias");
    try std.testing.expectError(error.IdentityConflict, history.move.intent.cleanup(context, parsed.value, false));
    try f.cache.dir.deleteFile(fixture.io, "anchor-alias");
    try history.move.file.link(session.dir, history.move.intent.note, session.dir, "note-alias");
    try std.testing.expectError(error.IdentityConflict, history.move.intent.cleanup(context, parsed.value, false));
    try session.dir.deleteFile(fixture.io, "note-alias");
    try history.move.intent.cleanup(context, parsed.value, false);
    try std.testing.expect(!history.move.intent.pending(fixture.io, f.cache.dir, &session.id));
    var bytes: [64]u8 = undefined;
    try std.testing.expectEqualStrings("intent payload", try session.dir.readFile(fixture.io, "log/events", &bytes));
}

test "a synced cancellation survives interrupted cleanup and can never recommit" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('b');
    const id = session.id;
    {
        var gate = try f.cache.gate(.exclusive);
        defer gate.release();
        const context: history.move.context.Context = .{ .source = &f.cache, .target = &f.cache, .authorities = &.{ gate.file, session.lock } };
        var buffer: history.name.Buffer = undefined;
        const target = history.name.trash(&buffer, &id);
        const parsed = try history.move.intent.start(fixture.allocator, context, &id, target, history.layout.moves.trash);
        defer parsed.deinit();
        try history.move.intent.commit(context, parsed.value);
        // Keep cleanup from unlinking a multiply named note. The actual
        // cancellation decision has to be durable before this failure.
        try history.move.file.link(session.dir, history.move.intent.note, session.dir, "note-alias");
        try std.testing.expectError(error.IdentityConflict, history.move.bridge.outcome(context, parsed.value, .expired, .{ .exited = history.move.windows.exits.rejected }));
        var anchor_buffer: history.name.Buffer = undefined;
        const saved = try history.move.intent.read(fixture.allocator, fixture.io, f.cache.dir, try history.move.intent.leaf(&anchor_buffer, &id), true);
        defer saved.deinit();
        try std.testing.expect(saved.value.cancelled and !saved.value.committed);
        try std.testing.expectError(error.NativeMoveCancelled, history.move.intent.commit(context, saved.value));
        try session.dir.deleteFile(fixture.io, "note-alias");
    }
    fixture.Fixture.abandon(&session);
    var plain = try history.base.Base.open(fixture.allocator, fixture.io, f.cache.path, .cache);
    defer plain.close();
    try std.testing.expect(!history.move.intent.pending(fixture.io, plain.dir, &id));
    var buffer: history.name.Buffer = undefined;
    try std.testing.expectError(error.FileNotFound, plain.dir.access(fixture.io, history.name.trash(&buffer, &id), .{}));
    var reopened = try history.session.Session.reopen(&plain, id);
    fixture.Fixture.abandon(&reopened);
}

test "every torn COMMIT journal is retained and never treated as a cancel" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const flag = "\nCOMMIT\n";
    for (1..flag.len) |cut| {
        var f = try fixture.Fixture.init();
        defer f.deinit();
        var session = try f.create('b');
        const id = session.id;
        {
            var gate = try f.cache.gate(.exclusive);
            defer gate.release();
            const context: history.move.context.Context = .{ .source = &f.cache, .target = &f.cache, .authorities = &.{ gate.file, session.lock } };
            var buffer: history.name.Buffer = undefined;
            const parsed = try history.move.intent.start(fixture.allocator, context, &id, history.name.trash(&buffer, &id), history.layout.moves.trash);
            defer parsed.deinit();
            var anchor_buffer: history.name.Buffer = undefined;
            const anchor = try history.move.intent.leaf(&anchor_buffer, &id);
            const held = try history.metadata.open(fixture.io, f.cache.dir, anchor, .read_write);
            defer held.close(fixture.io);
            try held.writePositionalAll(fixture.io, flag[0..cut], (try held.stat(fixture.io)).size);
            try held.sync(fixture.io);
            try std.testing.expectError(error.BadReceipt, history.move.intent.read(fixture.allocator, fixture.io, f.cache.dir, anchor, true));
        }
        fixture.Fixture.abandon(&session);
        var plain = try history.base.Base.open(fixture.allocator, fixture.io, f.cache.path, .cache);
        defer plain.close();
        try std.testing.expect(history.move.intent.pending(fixture.io, plain.dir, &id));
        try std.testing.expectError(error.Moving, history.remove.entryRemove(&plain, &id, .{}));
        var buffer: history.name.Buffer = undefined;
        try std.testing.expectError(error.FileNotFound, plain.dir.access(fixture.io, history.name.trash(&buffer, &id), .{}));
    }
}

test "version one intents remain unknown but verified rejection journals their cancellation" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('b');
    defer fixture.Fixture.abandon(&session);
    var gate = try f.cache.gate(.exclusive);
    defer gate.release();
    const context: history.move.context.Context = .{ .source = &f.cache, .target = &f.cache, .authorities = &.{ gate.file, session.lock } };
    var buffer: history.name.Buffer = undefined;
    const parsed = try history.move.intent.start(fixture.allocator, context, &session.id, history.name.trash(&buffer, &session.id), history.layout.moves.trash);
    defer parsed.deinit();
    var old = parsed.value;
    old.version = 1;
    const bytes = try std.json.Stringify.valueAlloc(fixture.allocator, old, .{});
    defer fixture.allocator.free(bytes);
    var anchor_buffer: history.name.Buffer = undefined;
    const anchor = try history.move.intent.leaf(&anchor_buffer, &session.id);
    const held = try history.metadata.open(fixture.io, f.cache.dir, anchor, .read_write);
    defer held.close(fixture.io);
    try std.testing.expectEqual(bytes.len, (try held.stat(fixture.io)).size);
    try held.writePositionalAll(fixture.io, bytes, 0);
    try held.sync(fixture.io);
    const saved = try history.move.intent.read(fixture.allocator, fixture.io, f.cache.dir, anchor, true);
    defer saved.deinit();
    try std.testing.expect(saved.value.committed);
    try std.testing.expectError(error.NativeMoveUnknown, history.move.bridge.settle(context, null, saved.value));
    try history.move.file.link(session.dir, history.move.intent.note, session.dir, "note-alias");
    try std.testing.expectError(error.IdentityConflict, history.move.bridge.outcome(context, saved.value, .refused, .{ .exited = history.move.windows.exits.rejected }));
    const cancelled = try history.move.intent.read(fixture.allocator, fixture.io, f.cache.dir, anchor, true);
    defer cancelled.deinit();
    try std.testing.expect(cancelled.value.cancelled and !cancelled.value.committed);
    try session.dir.deleteFile(fixture.io, "note-alias");
    try history.move.bridge.settle(context, null, cancelled.value);
    try std.testing.expect(!history.move.intent.pending(fixture.io, f.cache.dir, &session.id));
}
