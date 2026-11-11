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

test "Windows native peer activation stays off even when a native provider is attached" {
    const builtin = @import("builtin");
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('b');
    var moved = false;
    defer if (!moved) fixture.Fixture.abandon(&session);

    var gate = try f.cache.gate(.exclusive);
    defer gate.release();
    const ctx: history.move.context.Context = .{
        .source = &f.cache,
        .target = &f.cache,
        .authorities = &.{ gate.file, session.lock },
    };

    if (builtin.os.tag == .windows) {
        f.cache.native_provider = .{ .executable = "C:\\nonexistent-native-move-peer.exe", .sha256 = @splat('0') };
        defer f.cache.native_provider = null;
        try std.testing.expectError(error.OperationUnsupported, history.move.bridge.move(ctx, &session.id, "relocated", "publish\n"));

        session.dir.close(fixture.io);
        session.lock.close(fixture.io);
        moved = true;
        try history.move.dispatch.directory(
            .{ .source = &f.cache, .target = &f.cache, .authorities = &.{gate.file} },
            &session.id,
            "trash-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            "trash\n",
            null,
        );
        try f.cache.dir.access(fixture.io, "trash-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", .{});
    } else {
        try std.testing.expect(f.cache.native_provider == null);
        try std.testing.expectError(error.NativePeerUnavailable, history.move.bridge.move(ctx, &session.id, "relocated", "publish\n"));
    }
}
