const std = @import("std");
const builtin = @import("builtin");
const history = @import("ra8").host.history;
const fixture = @import("root_test.zig");

const io = fixture.io;
const layout = history.layout;
const Session = history.session.Session;

fn write(dir: std.Io.Dir, entry: []const u8, leaf: []const u8, data: []const u8) !void {
    var made = try dir.openDir(io, entry, .{});
    defer made.close(io);
    try made.writeFile(io, .{ .sub_path = leaf, .data = data });
}

fn absent(dir: std.Io.Dir, entry: []const u8) !void {
    try std.testing.expectError(error.FileNotFound, dir.access(io, entry, .{}));
}

/// A draft as a creator killed inside its publication leaves it: leased,
/// owned, marked as moving, with its final name already made and marked.
fn killedPublication(f: *fixture.Fixture, id: *const history.name.Id) !void {
    const callback = struct {
        fn reached(_: *anyopaque, phase: history.move.probe.Phase, _: std.Io.Dir, _: []const u8, _: std.Io.Dir, _: []const u8) !void {
            if (phase == .target_marked) return error.OwnedInterruption;
        }
    };
    var context: u8 = 0;
    var session = Session.create(&f.cache, .{ .id = id.*, .move_probe = .{ .context = &context, .reached = callback.reached } }) catch |err| {
        if (err == error.OwnedInterruption) return;
        return err;
    };
    // Exercise the same fallback transaction explicitly on native ext4.
    session.dir.close(io);
    defer session.lock.close(io);
    var gate = try f.cache.gate(.exclusive);
    defer gate.release();
    var buffer: history.name.Buffer = undefined;
    const draft = history.name.creating(&buffer, id);
    try history.move.preserve(io, f.cache.dir, id, f.cache.dir, draft);
    try std.testing.expectError(error.OwnedInterruption, history.move.tree.moveProbed(fixture.allocator, io, f.cache.dir, draft, f.cache.dir, id, layout.moves.publish, .{ .context = &context, .reached = callback.reached }));
}

test "host lifecycle killed publication is protected, carried on by recovery and then swept" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f = try fixture.Fixture.init();
    defer f.deinit();
    const id: history.name.Id = @splat('a');
    try killedPublication(&f, &id);
    try std.testing.expectError(error.Moving, Session.reopen(&f.cache, id));
    try std.testing.expectError(error.Moving, history.remove.entryRemove(&f.cache, &id, .{}));
    try f.cache.recover();
    var buffer: history.name.Buffer = undefined;
    try absent(f.cache.dir, history.name.creating(&buffer, &id));
    try std.testing.expect(!try history.move.tree.moving(io, f.cache.dir, &id));
    try std.testing.expectEqual(history.lock.State.free, history.lock.probe(io, f.cache.dir, &id));
    const report = try history.sweep.run(&f.cache, .{}, null);
    try std.testing.expectEqual(@as(u64, 1), report.removed);
    try absent(f.cache.dir, &id);
    try absent(f.cache.dir, history.name.lease(&buffer, &id));
}

test "host lifecycle recovery preserves foreign empty source and retires proven orphan lease" {
    var f = try fixture.Fixture.init();
    defer f.deinit();
    const live: history.name.Id = @splat('b');
    const gone: history.name.Id = @splat('c');
    const held = try history.lock.create(io, f.cache.dir, &live);
    (try history.lock.create(io, f.cache.dir, &gone)).close(io);
    // A move killed at its last step leaves its source empty and unmarked.
    var buffer: history.name.Buffer = undefined;
    try f.cache.dir.createDir(io, history.name.creating(&buffer, &gone), layout.directory_permissions);
    try f.cache.recover();
    try f.cache.dir.access(io, history.name.creating(&buffer, &gone), .{});
    try f.cache.dir.access(io, history.name.lease(&buffer, &live), .{});
    try std.testing.expectEqual(history.lock.State.held, history.lock.probe(io, f.cache.dir, &live));
    try f.cache.dir.access(io, history.name.lease(&buffer, &gone), .{});
    try f.cache.dir.deleteDir(io, history.name.creating(&buffer, &gone));
    try f.cache.recover();
    try absent(f.cache.dir, history.name.lease(&buffer, &gone));
    held.close(io);
    // A closed session keeps its lease, free, for whoever opens it next.
    var session = try f.create('d');
    const id = session.id;
    fixture.Fixture.abandon(&session);
    try f.cache.recover();
    try std.testing.expectEqual(history.lock.State.free, history.lock.probe(io, f.cache.dir, &id));
}

test "host lifecycle killed kept move is carried on from the cache root and reopens kept" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('e');
    const id = session.id;
    try session.dir.writeFile(io, .{ .sub_path = "log/events", .data = "kept bytes" });
    try session.keep();
    fixture.Fixture.abandon(&session);
    var receipt: [history.move.tree.limits.receipt]u8 = undefined;
    try history.move.receipt.start(fixture.allocator, io, f.cache.dir, &id, f.kept.dir, &id, try std.fmt.bufPrint(&receipt, layout.moves.keep ++ "{s}\n", .{f.kept.path}), null);
    try f.cache.recover();
    var buffer: history.name.Buffer = undefined;
    try absent(f.cache.dir, &id);
    try absent(f.cache.dir, history.name.lease(&buffer, &id));
    var kept = try Session.reopen(&f.kept, id);
    try std.testing.expect(kept.kept);
    var bytes: [64]u8 = undefined;
    try std.testing.expectEqualStrings("kept bytes", try kept.dir.readFile(io, "log/events", &bytes));
    try std.testing.expectEqual(history.lock.State.held, history.lock.probe(io, f.kept.dir, &id));
    fixture.Fixture.abandon(&kept);
}

test "host lifecycle recovery does not carry on a move for another host or a foreign marker" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f = try fixture.Fixture.init();
    defer f.deinit();
    const id: history.name.Id = @splat('f');
    try killedPublication(&f, &id);
    var buffer: history.name.Buffer = undefined;
    const draft = history.name.creating(&buffer, &id);
    try write(f.cache.dir, draft, layout.files.owner, "not an owner record");
    try f.cache.recover();
    try std.testing.expect(try history.move.tree.moving(io, f.cache.dir, draft));
    try std.testing.expect(try history.move.tree.moving(io, f.cache.dir, &id));
    const report = try history.sweep.run(&f.cache, .{}, null);
    try std.testing.expectEqual(@as(u64, 0), report.removed);
    try f.cache.dir.access(io, draft, .{});
}
