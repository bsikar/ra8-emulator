//! Mirrored unit tests for FPB-RA4T1 board wiring and boundary ticking
//! (`src/board/vendor/renesas/fpb_ra4t1.zig`).
const ra8 = @import("ra8");
const std = @import("std");

const Board = ra8.board.board.Board;
const catalog = ra8.chip.core.machine.catalog;
const cpu0_store = ra8.board.cpu0_store;
const fpb_ra4t1 = ra8.board.vendor.renesas.fpb_ra4t1;
const sau_attr = ra8.chip.periph.sau.attribution;

test "fpb_ra4t1 attachBlocks wires bus, IDAU, ROM defaults, and SCI9 console forwarding" {
    const board = try std.testing.allocator.create(Board);
    defer std.testing.allocator.destroy(board);
    board.* = Board.init(std.testing.allocator);
    defer board.deinit();
    board.machine = &catalog.ra4t1;

    var store: cpu0_store.Cpu0 = .{};
    defer store.close();
    store.store = try ra8.chip.core.cpu.memory.store.Store.initFor(null, catalog.ra4t1.memory);
    try fpb_ra4t1.attachBlocks(board, store.own());

    var pnr: [16]u8 = undefined;
    try store.own().read(0x0100_80F0, &pnr);
    try std.testing.expectEqualStrings("R7FA4T1BB3CFM   ", &pnr);
    try std.testing.expectEqual(sau_attr.State.secure, board.idau.answer(0x0000_0000).state);

    board.bus.write(0x4008_4004, 4, ~ra8.chip.vendor.renesas.ra4t1.mstp.bit.sci9);
    board.bus.write(0x4011_8902, 1, 0x20);
    board.bus.write(0x4011_8903, 1, 'O');
    board.bus.write(0x4011_8903, 1, 'K');
    board.bus.write(0x4011_8903, 1, '\n');
    try std.testing.expectEqualStrings("OK", board.serial.line.slice());

    try fpb_ra4t1.tick(board, store.own(), 1000, .cpu0);
    try std.testing.expect(board.time.base.now() > 0);
}
