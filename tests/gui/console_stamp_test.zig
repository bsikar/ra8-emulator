//! Covers RA8EMU-206's done condition: with the console feed and the
//! session event stream (RA8EMU-192) both watching the SCI, every byte the
//! console keeps carries the same time as its uart_byte event, and each
//! console line is stamped with its newline's event time.
const std = @import("std");
const ra8 = @import("ra8");
const Board = ra8.board.Board;
const api = ra8.core.session_api;
const sci = ra8.periph.sci;
const console_feed = ra8.gui.console_feed;
const console_log = ra8.gui.console_log;

const channel: usize = sci.console_channel;

fn boardNow(ctx: *anyopaque) u64 {
    const board: *Board = @ptrCast(@alignCast(ctx));
    return board.time.base.now();
}

fn register(offset: u32) u32 {
    return sci.win_base + @as(u32, @intCast(channel)) * sci.stride + offset;
}

fn send(board: *Board, text: []const u8, step_ns: u64) void {
    for (text) |byte| {
        board.time.base.advance(step_ns);
        board.serial.write(register(sci.off_tdr), 1, byte);
    }
}

test "console stamps equal the session stream's UART byte times" {
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var session: api.Session = .{ .live = undefined };
    ra8.board.session_events.attach(&board, &session);
    const subscription = session.event_stream.subscribe().?;
    var feed = console_feed.Feed{ .allocator = std.testing.allocator, .now = .{ .ctx = &board, .now = boardNow } };
    defer feed.deinit();
    feed.next = board.serial.tap;
    board.serial.tap = feed.tap();
    var logs: [sci.channels]console_log.Log = undefined;
    for (&logs) |*log| log.* = .init(std.testing.allocator, 8);
    defer for (&logs) |*log| log.deinit();
    board.serial.write(register(sci.off_ccr0), 4, sci.ccr0.te);
    send(&board, "ok\n", 40);
    send(&board, "go\n", 75);
    feed.publish();
    try std.testing.expectEqual(@as(u64, 0), try feed.drain(&logs));
    var events: [16]api.Event = undefined;
    const got = session.event_stream.read(subscription, &events).?;
    try std.testing.expectEqual(@as(usize, 6), got.count);
    try std.testing.expectEqual(@as(usize, 6), feed.inbox.items.len);
    for (feed.inbox.items, events[0..got.count]) |kept, event| {
        try std.testing.expectEqual(api.Event.Kind.uart_byte, event.kind);
        try std.testing.expectEqual(kept.byte, event.payload.uart.byte);
        try std.testing.expectEqual(kept.channel, event.payload.uart.channel);
        try std.testing.expectEqual(kept.at_ns, event.virtual_ns);
    }
    const lines = logs[channel].lines();
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("go", lines[1].text);
    try std.testing.expectEqual(events[2].virtual_ns, lines[0].at_ns);
    try std.testing.expectEqual(events[5].virtual_ns, lines[1].at_ns);
    try std.testing.expect(lines[0].at_ns < lines[1].at_ns);
}
