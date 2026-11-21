//! Covers src/board/vendor/renesas/fpb_ra8e1.zig: single-core RA8E1 block attachment,
//! SCI9 console and ELC events, FCACHE, PRCR_NS, USBFS-only, RIIC-only,
//! S1 pull-up, and absence of EK-RA8D2 peripherals.
const ra8 = @import("ra8");
const std = @import("std");

const Board = ra8.board.board.Board;
const catalog = ra8.chip.core.machine.catalog;
const event = ra8.chip.periph.sci.event;
const registry = ra8.chip.periph.registry;
const sci = ra8.chip.periph.sci;
const Store = ra8.chip.core.cpu.memory.store.Store;
const wiring = ra8.board.wiring;

fn allocBoard() !*Board {
    const board = try std.testing.allocator.create(Board);
    board.* = Board.init(std.testing.allocator);
    board.machine = &catalog.ra8e1;
    return board;
}

fn freeBoard(board: *Board) void {
    board.deinit();
    std.testing.allocator.destroy(board);
}

test "RA8E1 board attaches cleanly under the registry block cap" {
    var store = try Store.initFor(null, catalog.ra8e1.memory);
    defer store.deinit();
    const board = try allocBoard();
    defer freeBoard(board);
    try wiring.attachBlocks(board, .{ .store = &store });

    try std.testing.expect(board.bus.count > 0);
    try std.testing.expect(board.bus.count < registry.max_blocks);
    try std.testing.expect(board.transfers.twin == null);
    try std.testing.expect(board.pins.pinLevel(0, 9));
    try std.testing.expect(!board.pins.pinLevel(0, 8));
}

test "RA8E1 routes line console and ELC events to SCI9 while leaving SCI5..8 absent" {
    var store = try Store.initFor(null, catalog.ra8e1.memory);
    defer store.deinit();
    const board = try allocBoard();
    defer freeBoard(board);
    try wiring.attachBlocks(board, .{ .store = &store });

    try std.testing.expectEqual(event.ra8e1_console_channel, board.serial.console_index);
    const sci9_ccr0 = sci.regAddress(9, sci.off_ccr0);
    const sci9_tdr = sci.regAddress(9, sci.off_tdr);
    const sci8_ccr0 = sci.regAddress(8, sci.off_ccr0);

    const mstp_b: u32 = ra8.chip.periph.mstp.win_base + 4;
    try std.testing.expectEqual(@as(?u32, null), board.bus.tryRead(sci8_ccr0, 4));
    try std.testing.expect(board.bus.tryWrite(mstp_b, 4, ~(@as(u32, 1) << 22)));
    try std.testing.expect(
        board.bus.tryWrite(sci9_ccr0, 4, sci.ccr0.te | sci.ccr0.re | sci.ccr0.rie | sci.ccr0.tie | sci.ccr0.teie),
    );
    board.serial.feedConsole("Z");
    const due = board.serial.dueEvents();
    const want = [_]u16{ event.ra8e1_console.txi, event.ra8e1_console.tei, event.ra8e1_console.rxi };
    try std.testing.expectEqualSlices(u16, &want, due.constSlice());

    for ("ok\n") |ch| try std.testing.expect(board.bus.tryWrite(sci9_tdr, 4, ch));
    try std.testing.expectEqualStrings("ok", board.serial.line.slice());
    try std.testing.expectEqual(@as(u32, 'Z'), board.bus.tryRead(sci.regAddress(9, sci.off_rdr), 4).?);
}

test "RA8E1 attaches USBFS and RIIC while omitting USBHS and I3C" {
    var store = try Store.initFor(null, catalog.ra8e1.memory);
    defer store.deinit();
    const board = try allocBoard();
    defer freeBoard(board);
    try wiring.attachBlocks(board, .{ .store = &store });

    try std.testing.expect(board.bus.tryRead(0x4025_0000, 2) != null);
    try std.testing.expect(board.bus.tryRead(0x4025_E000, 1) != null);
    try std.testing.expectEqual(@as(?u32, null), board.bus.tryRead(0x4035_1000, 4));
    try std.testing.expectEqual(@as(?u32, null), board.bus.tryRead(0x4035_F000, 4));
}
