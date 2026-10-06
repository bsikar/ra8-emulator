//! Board event source wiring tests.
const std = @import("std");
const ra8 = @import("ra8");
const Board = ra8.board.Board;
const api = ra8.core.session_api;
const sci = ra8.periph.sci;

test "board UART GPIO LED and watchdog reset events use virtual time" {
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var session: api.Session = .{ .live = undefined };
    ra8.board.session_events.attach(&board, &session, .cpu0);
    const subscription = session.event_stream.subscribe().?;
    board.serial.write(sci.win_base + 8 * sci.stride + sci.off_ccr0, 4, sci.ccr0.te);
    board.serial.write(sci.win_base + 8 * sci.stride + sci.off_tdr, 1, 'Q');
    board.pins.applyWrite(ra8.periph.gpio.regAddress(6, ra8.periph.gpio.pcntr1), 4, (@as(u32, 1) << 16) | 1);
    board.time.base.advance(12);
    board.requestReset(.watchdog);
    var events: [8]api.Event = undefined;
    const got = session.event_stream.read(subscription, &events).?;
    try std.testing.expectEqual(@as(usize, 5), got.count);
    try std.testing.expectEqual(api.Event.Kind.uart_byte, events[0].kind);
    try std.testing.expectEqual(@as(u8, 'Q'), events[0].payload.uart.byte);
    try std.testing.expectEqual(api.Event.Kind.gpio_changed, events[1].kind);
    try std.testing.expectEqual(api.Event.Kind.led_changed, events[2].kind);
    try std.testing.expectEqual(api.Event.Kind.watchdog, events[3].kind);
    try std.testing.expectEqual(api.Event.Kind.reset, events[4].kind);
    try std.testing.expectEqual(@as(u64, 12), events[3].virtual_ns);
    try std.testing.expectEqual(@as(u64, 12), events[4].virtual_ns);
}
