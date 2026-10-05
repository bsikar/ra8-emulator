//! RA8EMU-678: the self-contained media and comms units saved with
//! non-default state and loaded into fresh units compare equal, and a
//! missing or short section changes nothing.
const std = @import("std");
const ra8 = @import("ra8");
const Board = ra8.board.Board;
const file = ra8.snapshot.file;
const media = ra8.snapshot.media;

fn Unit(comptime name: []const u8) type {
    return @FieldType(Board, name);
}

/// The Board's media and comms fields, under the Board's names.
const Stand = struct {
    microphone: Unit("microphone") = Unit("microphone").init(),
    can: Unit("can") = Unit("can").init(),
    lowpower: Unit("lowpower") = Unit("lowpower").init(),
    monitors: Unit("monitors") = Unit("monitors").init(),
    link: Unit("link") = Unit("link").init(),
    receiver: Unit("receiver") = Unit("receiver").init(),
    host: Unit("host") = Unit("host").init(),
};

fn busy() Stand {
    var board: Stand = .{};
    board.microphone.channels[0].running = true;
    board.microphone.channels[0].fifo[2] = 0x1234_5678;
    board.can.wakes = 3;
    board.lowpower.pending = 0x5;
    board.monitors.locked = false;
    board.monitors.dropped = 2;
    board.link.refcr = 0x3;
    board.receiver.gsct = 0x11;
    board.host.hsclksetr = 0x0F0F;
    return board;
}

fn saved(board: *const Stand, list: *std.ArrayList(u8)) !void {
    try file.writeHeader(list.writer());
    try media.save(board, list.writer());
}

test "every media and comms unit round-trips" {
    const board = busy();
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    try saved(&board, &list);
    var target: Stand = .{};
    try media.load(&target, list.items);
    try std.testing.expectEqualDeep(board, target);
}

test "a missing or short section changes nothing" {
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    try file.writeHeader(list.writer());
    var target: Stand = .{};
    try std.testing.expectError(error.Missing, media.load(&target, list.items));
    list.clearRetainingCapacity();
    const board = busy();
    try saved(&board, &list);
    const cut = list.items[0 .. list.items.len - 3];
    try std.testing.expect(std.meta.isError(media.load(&target, cut)));
    try std.testing.expectEqualDeep(Stand{}, target);
}
