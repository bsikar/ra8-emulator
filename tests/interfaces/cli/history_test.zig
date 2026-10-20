//! Tests for src/interfaces/cli/history_cli.zig.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");
const mod = cli_app.history_cli;
const history = ra8.host.history;

test "the history command line parses its four tools" {
    const listed = try mod.parse(&.{ "ra8_emulator", "history", "ls", "--root", "/tmp/h" });
    try std.testing.expectEqual(mod.Op.ls, listed.op);
    try std.testing.expectEqualStrings("/tmp/h", listed.root);
    try std.testing.expectEqual(@as(?[]const u8, null), listed.entry);

    try std.testing.expectError(error.Usage, mod.parse(&.{ "ra8_emulator", "history" }));
    try std.testing.expectError(error.Usage, mod.parse(&.{ "ra8_emulator", "history", "du" }));
    try std.testing.expectError(error.Usage, mod.parse(&.{ "ra8_emulator", "history", "nope", "--root", "/h" }));
    try std.testing.expectError(error.Usage, mod.parse(&.{ "ra8_emulator", "history", "rm", "--root", "/h" }));
    try std.testing.expectError(error.Usage, mod.parse(&.{ "ra8_emulator", "history", "ls", "--root", "/h", "extra" }));
    try std.testing.expectError(error.Usage, mod.parse(&.{ "ra8_emulator", "history", "ls", "--kept", "--root", "/h" }));
    try std.testing.expectError(error.Usage, mod.parse(&.{ "ra8_emulator", "history", "ls", "--root" }));
    try std.testing.expectError(error.Usage, mod.parse(&.{ "ra8_emulator", "history", "ls", "--root", "/a", "--root", "/b" }));

    const dropped = try mod.parse(&.{ "ra8_emulator", "history", "rm", "--root", "/h", "--kept", "deadbeef0102030405060708090a0b0c" });
    try std.testing.expectEqual(mod.Op.rm, dropped.op);
    try std.testing.expect(dropped.kept);
    try std.testing.expectEqualStrings("deadbeef0102030405060708090a0b0c", dropped.entry.?);

    const counted = try mod.parse(&.{ "ra8_emulator", "history", "du", "--root", "/h", "deadbeef0102030405060708090a0b0c" });
    try std.testing.expectEqualStrings("deadbeef0102030405060708090a0b0c", counted.entry.?);
}

test "the history command line lists, measures and removes a root's sessions" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    var base = try history.base.Base.open(allocator, io, root, .cache);
    defer base.close();
    var session = try history.session.Session.create(&base, .{});
    defer session.dir.close(io);
    defer session.lock.close(io);

    var listed: [4096]u8 = undefined;
    var list_stream: std.Io.Writer = .fixed(&listed);
    try std.testing.expectEqual(@as(u8, 0), try mod.listRoot(&base, &list_stream));
    const shown = listed[0..list_stream.end];
    try std.testing.expect(std.mem.indexOf(u8, shown, "live") != null);
    try std.testing.expect(std.mem.indexOf(u8, shown, "kept") == null);

    var entries = try history.catalog.Iterator.init(&base);
    const entry = (try entries.next()).?;
    try std.testing.expectEqual(history.catalog.Status.live, entry.status);
    try std.testing.expectEqual(history.name.Kind.session, entry.kind);

    var counted: [4096]u8 = undefined;
    var du_stream: std.Io.Writer = .fixed(&counted);
    try std.testing.expectEqual(@as(u8, 0), try mod.reportBytes(&base, &du_stream, entry.name));
    try std.testing.expect(std.mem.indexOf(u8, counted[0..du_stream.end], entry.name) != null);
    var counted_all: [4096]u8 = undefined;
    var du_all_stream: std.Io.Writer = .fixed(&counted_all);
    try std.testing.expectEqual(@as(u8, 0), try mod.reportBytes(&base, &du_all_stream, null));
    try std.testing.expect(std.mem.indexOf(u8, counted_all[0..du_all_stream.end], "total ") != null);
}

test "the history command line sweeps a closed session's orphans and removes it" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    var base = try history.base.Base.open(allocator, io, root, .cache);
    defer base.close();
    var session = try history.session.Session.create(&base, .{});
    const id = session.id;
    var objects = try history.paths.area(&session, .objects);
    defer objects.close(io);
    var file = try objects.createFile(io, "deadbeef0102030405060708090a0b0c", .{ .read = true });
    try file.writeStreamingAll(io, "orphan bytes");
    file.close(io);
    // An abandoned session: the owner record and every byte stay, the
    // lock goes, so the catalog reports it stale and the sweep may take it.
    session.dir.close(io);
    session.lock.close(io);

    var swept: [4096]u8 = undefined;
    var sweep_stream: std.Io.Writer = .fixed(&swept);
    try std.testing.expectEqual(@as(u8, 0), try mod.sweepClosed(allocator, &base, &sweep_stream));
    try std.testing.expect(std.mem.indexOf(u8, swept[0..sweep_stream.end], "1 orphan objects") != null);

    var dropped: [4096]u8 = undefined;
    var rm_stream: std.Io.Writer = .fixed(&dropped);
    const name = try std.fmt.allocPrint(allocator, "{s}", .{&id});
    defer allocator.free(name);
    try std.testing.expectEqual(@as(u8, 0), try mod.removeOne(&base, &rm_stream, name, false));
    try std.testing.expectError(error.NotFound, base.owns(name));
}
