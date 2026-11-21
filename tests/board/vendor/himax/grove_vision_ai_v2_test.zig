//! Covers src/board/vendor/himax/grove_vision_ai_v2.zig: HX peripheral attachment, MMIO faults on
//! unmapped Ethos-U55, 400:150 MHz ratio, and CM55S hold/release via SCU.
const ra8 = @import("ra8");
const std = @import("std");

const Board = ra8.board.board.Board;
const board_snap = ra8.board.snapshot.board;
const catalog = ra8.chip.core.machine.catalog;
const file = ra8.snapshot.file;
const Guest = ra8.chip.core.cpu.memory.guest.Guest;
const hx_periph = ra8.chip.vendor.himax.hx6538;
const Store = ra8.chip.core.cpu.memory.store.Store;
const wiring = ra8.board.wiring;

test "HX6538 board attaches SCU/Mailbox/UART/Timer, exposes 400 MHz clock, and faults on U55" {
    var store = try Store.initFor(null, catalog.hx6538.memory);
    defer store.deinit();
    const memory: Guest = .{ .store = &store };

    const board = try std.testing.allocator.create(Board);
    defer std.testing.allocator.destroy(board);
    board.* = Board.init(std.testing.allocator);
    defer board.deinit();
    board.machine = &catalog.hx6538;
    try wiring.attachBlocks(board, memory);

    try std.testing.expectEqual(@as(u64, 400_000_000), board.time.base.hz);
    try std.testing.expect(board.bus.count > 0);
    try std.testing.expect(board.bus.count < ra8.chip.periph.registry.max_blocks);

    // Unmapped MMIO including HX6538 Ethos-U55 @ 0x4302_0000 / 0x5302_0000 faults cleanly.
    try std.testing.expectEqual(@as(?u32, null), board.bus.tryRead(0x4302_0000, 4));
    try std.testing.expectEqual(@as(?u32, null), board.bus.tryRead(0x5302_0000, 4));
    try std.testing.expect(!board.bus.tryWrite(0x4302_0000, 4, 1));
    try std.testing.expect(!board.bus.tryWrite(0x5302_0000, 4, 1));

    // Bit-28 NS/S alias folding on Mailbox and UART0 console output.
    try std.testing.expect(board.bus.tryWrite(0x5400_A100, 4, 0xABCD_1234));
    try std.testing.expectEqual(@as(?u32, 0xABCD_1234), board.bus.tryRead(0x4400_A100, 4));
    for ("uart-ns\n") |b| try std.testing.expect(board.bus.tryWrite(0x4400_3000, 4, b));
    try std.testing.expectEqualStrings("uart-ns", board.serial.line.slice());
}

test "HX6538 CM55S boots held at 150:400 MHz ratio until SCU INITSVTOR/STATE/CPUWAIT release" {
    var store = try Store.initFor(null, catalog.hx6538.memory);
    defer store.deinit();
    const memory: Guest = .{ .store = &store };

    const board = try std.testing.allocator.create(Board);
    defer std.testing.allocator.destroy(board);
    board.* = Board.init(std.testing.allocator);
    defer board.deinit();
    board.machine = &catalog.hx6538;
    try wiring.attachBlocks(board, memory);

    const w = wiring.cpu1(board);
    try std.testing.expect(w.initial_hold);
    try std.testing.expect(w.hold_while_gated);
    try std.testing.expect(!w.releaseRunning());

    var state: ra8.chip.core.second.core.State = .{ .wiring = w, .held = true };
    try std.testing.expectEqual(@as(u32, 384), state.turn(1024));
    try std.testing.expect(state.heldInReset(memory));

    // CM55M configures CM55S vector table and releases STATE=1, CPUWAIT=0.
    const initsvtor_addr = hx_periph.scu.aon_base + hx_periph.scu.aon_regs.cm55s_initsvtor;
    try std.testing.expect(board.bus.tryWrite(initsvtor_addr, 4, 0x3402_0000));
    try std.testing.expect(board.bus.tryWrite(hx_periph.scu.aon_base + hx_periph.scu.aon_regs.cm55s_state, 4, 1));
    try std.testing.expect(state.heldInReset(memory));
    try std.testing.expect(board.bus.tryWrite(hx_periph.scu.aon_base + hx_periph.scu.aon_regs.cm55s_cpuwait, 4, 0));

    try std.testing.expect(!state.heldInReset(memory));
    try std.testing.expect(state.unvectored);
    try std.testing.expectEqual(@as(u32, 0x3402_0000), state.vector_base);
}

fn saveBoardSnapshot(board: *const Board, out: *std.Io.Writer.Allocating) !void {
    try file.writeHeader(&out.writer);
    try board_snap.save(board, &out.writer);
}

test "HX6538 snapshots tag [0xFF, hx6538] and refuse WrongPart across ra8d2 and cortex-m55" {
    var hx_bytes = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer hx_bytes.deinit();
    {
        var store = try Store.initFor(null, catalog.hx6538.memory);
        defer store.deinit();
        const board = try std.testing.allocator.create(Board);
        defer std.testing.allocator.destroy(board);
        board.* = Board.init(std.testing.allocator);
        defer board.deinit();
        board.machine = &catalog.hx6538;
        try wiring.attachBlocks(board, .{ .store = &store });
        board.c6.reply = .{0x65};
        try saveBoardSnapshot(board, &hx_bytes);
        const part_sec = (try file.Reader.find(hx_bytes.written(), .part)).?;
        try std.testing.expectEqualSlices(u8, &([_]u8{board_snap.named_part_tag} ++ "hx6538".*), part_sec.payload);
    }

    {
        var store = try Store.initFor(null, catalog.hx6538.memory);
        defer store.deinit();
        const board = try std.testing.allocator.create(Board);
        defer std.testing.allocator.destroy(board);
        board.* = Board.init(std.testing.allocator);
        defer board.deinit();
        board.machine = &catalog.hx6538;
        try wiring.attachBlocks(board, .{ .store = &store });
        try board_snap.load(board, hx_bytes.written());
        try std.testing.expectEqual(@as(u8, 0x65), board.c6.reply[0]);
    }

    var d2_bytes = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer d2_bytes.deinit();
    {
        var store = try Store.initFor(null, catalog.ra8d2.memory);
        defer store.deinit();
        const board = try std.testing.allocator.create(Board);
        defer std.testing.allocator.destroy(board);
        board.* = Board.init(std.testing.allocator);
        defer board.deinit();
        board.part = .ra8d2;
        try wiring.attachBlocks(board, .{ .store = &store });
        board.c6.reply = .{0x11};
        try saveBoardSnapshot(board, &d2_bytes);
        try std.testing.expectError(error.WrongPart, board_snap.load(board, hx_bytes.written()));
        try std.testing.expectEqual(@as(u8, 0x11), board.c6.reply[0]);
    }

    {
        var store = try Store.initFor(null, catalog.cortex_m55.memory);
        defer store.deinit();
        const board = try std.testing.allocator.create(Board);
        defer std.testing.allocator.destroy(board);
        board.* = Board.init(std.testing.allocator);
        defer board.deinit();
        board.machine = &catalog.cortex_m55;
        try wiring.attachBlocks(board, .{ .store = &store });
        board.c6.reply = .{0x22};
        try std.testing.expectError(error.WrongPart, board_snap.load(board, hx_bytes.written()));
        try std.testing.expectEqual(@as(u8, 0x22), board.c6.reply[0]);
    }

    {
        var store = try Store.initFor(null, catalog.hx6538.memory);
        defer store.deinit();
        const board = try std.testing.allocator.create(Board);
        defer std.testing.allocator.destroy(board);
        board.* = Board.init(std.testing.allocator);
        defer board.deinit();
        board.machine = &catalog.hx6538;
        try wiring.attachBlocks(board, .{ .store = &store });
        board.c6.reply = .{0x33};
        try std.testing.expectError(error.WrongPart, board_snap.load(board, d2_bytes.written()));
        try std.testing.expectEqual(@as(u8, 0x33), board.c6.reply[0]);
    }
}
