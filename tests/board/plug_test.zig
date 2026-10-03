//! Covers src/board/plug.zig: which block a catalog model's device lands
//! on, the channels already taken, and the --attach asks wiring plugs.
const std = @import("std");
const ra8 = @import("ra8");

const Board = ra8.board.Board;
const plug = Board.plug;
const model = ra8.periph.registry.model;

fn make(arena: std.mem.Allocator, spec: []const u8) !struct { model.catalog.Instance, model.endpoint.Endpoint } {
    const ask = try model.request.parse(spec);
    return .{ try model.parts.all.make(arena, ask.name, ask.at), ask.at };
}

test "an SPI model on spi1 exchanges frames through the channel" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    const made, const at = try make(arena.allocator(), "eink@spi:spi1@ssl0");
    try plug.one(&board, made.device, at);
    const line = board.spi.channels[1].device orelse return error.NotPlugged;
    const panel: *ra8.periph.eink.Panel = @ptrCast(@alignCast(made.state));
    try std.testing.expectEqual(panel.exchange(0x00), line.exchange(0x00));
    try std.testing.expect(board.spi.channels[0].device == null);
}

test "a UART model on sci3 answers what the channel sends it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    const made, const at = try make(arena.allocator(), "modem@uart:sci3");
    try plug.one(&board, made.device, at);
    const line = board.serial.channels[3].device orelse return error.NotPlugged;
    try std.testing.expectEqual(@as(usize, 0), line.feed('A').len);
    try std.testing.expectEqual(@as(usize, 0), line.feed('T').len);
    try std.testing.expectEqualStrings("\r\nOK\r\n", line.feed('\r'));
}

test "a channel that already has a device is refused, not replaced" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    const first, const at = try make(arena.allocator(), "modem@uart:sci5");
    try plug.one(&board, first.device, at);
    const second, _ = try make(arena.allocator(), "modem@uart:sci5");
    try std.testing.expectError(error.ChannelTaken, plug.one(&board, second.device, at));
    const kept = board.serial.channels[5].device orelse return error.NotPlugged;
    try std.testing.expectEqual(first.state, kept.context);
}

test "the kept asks are plugged on their lines, I2C included" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    const asks = [_]model.request.Request{
        try model.request.parse("max17048@i2c:riic@0x37"),
        try model.request.parse("eink@spi:spi1@ssl2"),
        try model.request.parse("modem@uart:sci4"),
    };
    board.asks.keep(arena.allocator(), &asks);
    try plug.all(&board);
    try std.testing.expect(board.wire.controller.devices.find(0x37) != null);
    try std.testing.expect(board.spi.channels[1].device != null);
    try std.testing.expect(board.serial.channels[4].device != null);
}

test "an ask that lands on a fitted Click part is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bus = ra8.periph.registry.Bus.init(std.testing.allocator);
    defer bus.deinit();
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    board.wire.click = true;
    try board.wire.attach(&bus);
    board.asks.keep(arena.allocator(), &.{try model.request.parse("max17048@i2c:touch@0x36")});
    try std.testing.expectError(error.AddressTaken, plug.all(&board));
}
