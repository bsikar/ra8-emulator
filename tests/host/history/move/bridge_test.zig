const std = @import("std");
const builtin = @import("builtin");
const history = @import("ra8").host.history;
const fixture = @import("../root_test.zig");

test "native bridge without a supplied peer makes no intent or destination" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('d');
    defer fixture.Fixture.abandon(&session);
    var gate = try f.cache.gate(.exclusive);
    defer gate.release();
    try std.testing.expectError(error.NativePeerUnavailable, history.move.bridge.move(.{ .source = &f.cache, .target = &f.cache, .authorities = &.{ gate.file, session.lock } }, &session.id, "target", "publish\n"));
    try std.testing.expect(!history.move.intent.pending(fixture.io, f.cache.dir, &session.id));
    try std.testing.expectError(error.FileNotFound, f.cache.dir.access(fixture.io, "target", .{}));
}

test "bad native bounds fail before provider access or durable intent" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('d');
    defer fixture.Fixture.abandon(&session);
    f.cache.native_provider = .{ .executable = "/missing-peer.exe", .sha256 = @splat(0), .bounds = .{ .ready = 0 } };
    var gate = try f.cache.gate(.exclusive);
    defer gate.release();
    var buffer: history.name.Buffer = undefined;
    const target = history.name.trash(&buffer, &session.id);
    try std.testing.expectError(error.BadBounds, history.move.bridge.move(.{ .source = &f.cache, .target = &f.cache, .authorities = &.{ gate.file, session.lock } }, &session.id, target, history.layout.moves.trash));
    try std.testing.expect(!history.move.intent.pending(fixture.io, f.cache.dir, &session.id));
    try std.testing.expectError(error.FileNotFound, session.dir.access(fixture.io, history.move.intent.note, .{}));
    try std.testing.expectError(error.FileNotFound, f.cache.dir.access(fixture.io, target, .{}));
}

test "nonsuccess replies with missing wrong or abnormal exits retain committed intent" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('d');
    defer fixture.Fixture.abandon(&session);
    var gate = try f.cache.gate(.exclusive);
    defer gate.release();
    const context: history.move.context.Context = .{ .source = &f.cache, .target = &f.cache, .authorities = &.{ gate.file, session.lock } };
    var buffer: history.name.Buffer = undefined;
    const target = history.name.trash(&buffer, &session.id);
    const parsed = try history.move.intent.start(fixture.allocator, context, &session.id, target, history.layout.moves.trash);
    defer parsed.deinit();
    try history.move.intent.commit(context, parsed.value);
    for ([_]history.move.wire.Status{ .collision, .cross_device, .refused, .expired }) |status| {
        try std.testing.expectError(error.NativeMoveUnknown, history.move.bridge.outcome(context, parsed.value, status, null, history.move.deadline.Deadline.after(fixture.io, 2_000)));
        for ([_]std.process.Child.Term{ .{ .exited = 0 }, .{ .exited = 1 }, .{ .exited = history.move.windows.exits.expired }, .{ .exited = history.move.windows.exits.drained }, .{ .exited = history.move.windows.exits.unready }, .{ .exited = history.move.windows.exits.unsettled }, .{ .signal = .KILL } }) |term| {
            try std.testing.expectError(error.NativePeerFailed, history.move.bridge.outcome(context, parsed.value, status, term, history.move.deadline.Deadline.after(fixture.io, 2_000)));
        }
    }
    var anchor_buffer: history.name.Buffer = undefined;
    const saved = try history.move.intent.read(fixture.allocator, fixture.io, f.cache.dir, try history.move.intent.leaf(&anchor_buffer, &session.id), true);
    defer saved.deinit();
    try std.testing.expect(saved.value.committed);
    try std.testing.expect(!saved.value.cancelled);
    try std.testing.expectError(error.NativeMoveUnknown, history.move.bridge.settle(context, null, saved.value));
    try session.dir.access(fixture.io, history.move.intent.note, .{});
    try std.testing.expectError(error.FileNotFound, f.cache.dir.access(fixture.io, target, .{}));
}

test "every matching rejection retires intent without moving its source" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const cases = .{
        .{ history.move.wire.Status.collision, error.PathAlreadyExists },
        .{ history.move.wire.Status.cross_device, error.CrossDevice },
        .{ history.move.wire.Status.refused, error.NativeMoveRefused },
        .{ history.move.wire.Status.expired, error.NativeMoveExpired },
    };
    inline for (cases) |case| {
        var f = try fixture.Fixture.init();
        defer f.deinit();
        var session = try f.create('d');
        defer fixture.Fixture.abandon(&session);
        var gate = try f.cache.gate(.exclusive);
        defer gate.release();
        const context: history.move.context.Context = .{ .source = &f.cache, .target = &f.cache, .authorities = &.{ gate.file, session.lock } };
        var buffer: history.name.Buffer = undefined;
        const target = history.name.trash(&buffer, &session.id);
        const parsed = try history.move.intent.start(fixture.allocator, context, &session.id, target, history.layout.moves.trash);
        defer parsed.deinit();
        try history.move.intent.commit(context, parsed.value);
        try std.testing.expectError(case[1], history.move.bridge.outcome(context, parsed.value, case[0], .{ .exited = history.move.windows.exits.rejected }, history.move.deadline.Deadline.after(fixture.io, 2_000)));
        try std.testing.expect(!history.move.intent.pending(fixture.io, f.cache.dir, &session.id));
        try std.testing.expectError(error.FileNotFound, session.dir.access(fixture.io, history.move.intent.note, .{}));
        try std.testing.expect(parsed.value.source.same(try history.move.file.state(f.cache.dir, &session.id)));
        try std.testing.expectError(error.FileNotFound, f.cache.dir.access(fixture.io, target, .{}));
    }
}

test "an ended admission publishes neither a cancellation nor an arrival" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('d');
    defer fixture.Fixture.abandon(&session);
    var gate = try f.cache.gate(.exclusive);
    defer gate.release();
    const context: history.move.context.Context = .{ .source = &f.cache, .target = &f.cache, .authorities = &.{ gate.file, session.lock } };
    var buffer: history.name.Buffer = undefined;
    const target = history.name.trash(&buffer, &session.id);
    const parsed = try history.move.intent.start(fixture.allocator, context, &session.id, target, history.layout.moves.trash);
    defer parsed.deinit();
    try history.move.intent.commit(context, parsed.value);
    const ended: history.move.deadline.Admission = .begin(fixture.io, 0);
    for ([_]history.move.wire.Status{ .success, .collision, .cross_device, .refused, .expired }) |status| {
        try std.testing.expectError(error.NativeMoveUnknown, history.move.bridge.publish(context, parsed.value, ended, history.move.deadline.Deadline.after(fixture.io, 2_000), status));
    }
    var anchor_buffer: history.name.Buffer = undefined;
    const saved = try history.move.intent.read(fixture.allocator, fixture.io, f.cache.dir, try history.move.intent.leaf(&anchor_buffer, &session.id), true);
    defer saved.deinit();
    try std.testing.expect(saved.value.committed and !saved.value.cancelled);
    try session.dir.access(fixture.io, history.move.intent.note, .{});
    // The same verdict inside an open admission is published.
    try std.testing.expectError(error.PathAlreadyExists, history.move.bridge.publish(context, parsed.value, .begin(fixture.io, 60_000), history.move.deadline.Deadline.after(fixture.io, 2_000), .collision));
    try std.testing.expect(!history.move.intent.pending(fixture.io, f.cache.dir, &session.id));
    try std.testing.expect(parsed.value.source.same(try history.move.file.state(f.cache.dir, &session.id)));
}

test "verified arrival survives slow reap and named watchdog drain exit" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    for ([_]?std.process.Child.Term{ null, .{ .exited = history.move.windows.exits.success }, .{ .exited = history.move.windows.exits.drained } }) |term| {
        var f = try fixture.Fixture.init();
        defer f.deinit();
        var session = try f.create('d');
        var source_open = true;
        defer {
            if (source_open) session.dir.close(fixture.io);
            session.lock.close(fixture.io);
        }
        var gate = try f.cache.gate(.exclusive);
        defer gate.release();
        const context: history.move.context.Context = .{ .source = &f.cache, .target = &f.cache, .authorities = &.{ gate.file, session.lock } };
        var buffer: history.name.Buffer = undefined;
        const target = history.name.trash(&buffer, &session.id);
        const parsed = try history.move.intent.start(fixture.allocator, context, &session.id, target, history.layout.moves.trash);
        defer parsed.deinit();
        try history.move.intent.commit(context, parsed.value);
        try std.testing.expectError(error.NativeMoveUnknown, history.move.bridge.outcome(context, parsed.value, .success, term, history.move.deadline.Deadline.after(fixture.io, 2_000)));
        // Fixture-only arrival into a checked absent name. DrvFS does not
        // implement renamePreserve. Its renamed path is invisible until the
        // original directory handle closes, as the real peer does on exit.
        try std.testing.expectError(error.FileNotFound, f.cache.dir.access(fixture.io, target, .{}));
        session.dir.close(fixture.io);
        source_open = false;
        try f.cache.dir.rename(&session.id, f.cache.dir, target, fixture.io);
        try std.testing.expectError(error.NativePeerFailed, history.move.bridge.outcome(context, parsed.value, .success, .{ .exited = 1 }, history.move.deadline.Deadline.after(fixture.io, 2_000)));
        try history.move.bridge.outcome(context, parsed.value, .success, term, history.move.deadline.Deadline.after(fixture.io, 2_000));
        try std.testing.expect(!history.move.intent.pending(fixture.io, f.cache.dir, &session.id));
        try std.testing.expect(parsed.value.source.same(try history.move.file.state(f.cache.dir, target)));
        var arrived = try f.cache.dir.openDir(fixture.io, target, .{});
        defer arrived.close(fixture.io);
        try std.testing.expectError(error.FileNotFound, arrived.access(fixture.io, history.move.intent.note, .{}));
    }
}
