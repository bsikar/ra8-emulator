const std = @import("std");
const ra8 = @import("ra8");
const watches = ra8.rpc.workspace_watch;
const wire = ra8.rpc.workspace_wire;
const io = std.testing.io;

test "workspace watch IDs are bounded, connection-owned and never reused after clear" {
    var first: watches.Table = .{};
    var other: watches.Table = .{};
    const id = try first.add("file", .{});
    try std.testing.expectError(error.InvalidWatch, other.remove(id));
    first.clear();
    const next = try first.add("file", .{});
    try std.testing.expect(next > id);
    try std.testing.expectError(error.InvalidWatch, first.remove(id));
    for (1..watches.capacity) |_| _ = try first.add("another", .{});
    try std.testing.expectError(error.TooManyWatches, first.add("overflow", .{}));
    try first.remove(next);
    _ = try first.add("replacement", .{});
}

const Sink = struct {
    count: usize = 0,
    state: wire.State = .changed,
    id: u32 = 0,
    pub fn emit(self: *Sink, comptime T: type, topic: u16, change: T, tx: []u8) !void {
        _ = tx;
        try std.testing.expectEqual(wire.changed_topic, topic);
        try std.testing.expectEqualStrings("watched", change.path);
        const version = try wire.decodeVersion(change.version);
        if (change.state == .removed) try std.testing.expectEqual((wire.Version{}).kind, version.kind);
        self.count += 1;
        self.id = change.id;
        self.state = change.state;
    }
};

test "workspace watch reconciliation detects external creation and removal and unwatch stops delivery" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: ra8.host.workspace.Workspace = .{ .dir = tmp.dir, .io = io };
    var context: ra8.rpc.session.server.Context = .{ .session = undefined, .scratch = &.{}, .workspace = &root };
    const id = try context.workspace_watches.add("watched", try root.observe("watched"));
    var sink: Sink = .{};
    try watches.pump(&context, &sink, &.{});
    try std.testing.expectEqual(@as(usize, 0), sink.count);
    try tmp.dir.writeFile(io, .{ .sub_path = "watched", .data = "outside edit" });
    context.workspace_watches.next_poll_ns = 0;
    try watches.pump(&context, &sink, &.{});
    try std.testing.expectEqual(@as(usize, 1), sink.count);
    try std.testing.expectEqual(id, sink.id);
    try tmp.dir.deleteFile(io, "watched");
    context.workspace_watches.next_poll_ns = 0;
    try watches.pump(&context, &sink, &.{});
    try std.testing.expectEqual(@as(usize, 2), sink.count);
    try std.testing.expectEqual(wire.State.removed, sink.state);
    try context.workspace_watches.remove(id);
    try tmp.dir.writeFile(io, .{ .sub_path = "watched", .data = "no delivery" });
    try watches.pump(&context, &sink, &.{});
    try std.testing.expectEqual(@as(usize, 2), sink.count);
}
