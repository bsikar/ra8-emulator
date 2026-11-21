//! Unit tests for RA4T1 board snapshot save/load and live pointer rebinding.
const ra8 = @import("ra8");
const std = @import("std");

const Board = ra8.board.board.Board;
const catalog = ra8.chip.core.machine.catalog;
const cpu0_store = ra8.board.cpu0_store;
const file = ra8.snapshot.file;
const section = ra8.board.snapshot.board;

const Rig = struct {
    cpu0: cpu0_store.Cpu0 = .{},
    board: *Board,

    fn create(machine: *const ra8.chip.core.machine.Machine) !*Rig {
        const rig = try std.testing.allocator.create(Rig);
        errdefer std.testing.allocator.destroy(rig);
        const board = try std.testing.allocator.create(Board);
        errdefer std.testing.allocator.destroy(board);
        board.* = Board.init(std.testing.allocator);
        errdefer board.deinit();
        board.machine = machine;
        rig.* = .{ .board = board };
        rig.cpu0.store = try ra8.chip.core.cpu.memory.store.Store.initFor(null, machine.memory);
        errdefer rig.cpu0.close();
        try ra8.board.wiring.attachBlocks(rig.board, rig.cpu0.own());
        try ra8.board.wiring.primeWindows(rig.board, rig.cpu0.own(), ra8.board.wiring.cpu0Windows(rig.board));
        return rig;
    }

    fn destroy(rig: *Rig) void {
        rig.board.deinit();
        std.testing.allocator.destroy(rig.board);
        rig.cpu0.close();
        std.testing.allocator.destroy(rig);
    }
};

test "RA4T1 board snapshot preserves registers and rebinds live IDAU and serial sink" {
    var saved: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer saved.deinit();
    {
        const rig = try Rig.create(&catalog.ra4t1);
        defer rig.destroy();

        rig.board.bus.write(0x4001_E3FE, 2, 0xA513); // PRC0 | PRC1 | PRC4
        rig.board.bus.write(0x4001_E037, 1, 0x02); // 20 MHz HOCO
        rig.board.bus.write(0x400E_0018, 4, 1 << 15); // 32 KB S+NSC Code Flash total via CFSAMONA
        rig.board.bus.write(0x400E_001C, 4, 32 << 10); // 32 KB Secure Code Flash via CFSAMONB
        rig.board.bus.write(0x4008_0040, 4, (@as(u32, 1 << 7) << 16) | (1 << 7)); // P207 high

        try file.writeHeader(&saved.writer);
        try section.save(rig.board, &saved.writer);
    }

    try std.testing.expectEqualStrings("ra4t1", try section.machineNameOf(saved.written()));
    try std.testing.expectError(section.Error.WrongPart, section.machineOf(&catalog.ra8d2, saved.written()));
    try std.testing.expectError(section.Error.WrongPart, section.machineOf(&catalog.cortex_m33, saved.written()));

    const fresh = try Rig.create(&catalog.ra4t1);
    defer fresh.destroy();
    try section.load(fresh.board, saved.written());

    try std.testing.expectEqual(@as(u8, 0x02), fresh.board.ra4t1.sysc.hococr2);
    try std.testing.expectEqual(@as(u16, 0x01C3), fresh.board.ra4t1.port.pidrOf(2));
    try std.testing.expectEqual(
        ra8.chip.periph.sau.attribution.State.non_secure,
        fresh.board.idau.answer(0x0001_0000).state,
    );

    // Live PRCR.PRC4 protection and SCI9 serial sink still target `fresh.board` after commit.
    fresh.board.bus.write(0x4008_4004, 4, ~ra8.chip.vendor.renesas.ra4t1.mstp.bit.sci9);
    fresh.board.bus.write(0x4011_8902, 1, 0x20);
    fresh.board.bus.write(0x4011_8903, 1, 'Z');
    fresh.board.bus.write(0x4011_8903, 1, '\n');
    try std.testing.expectEqualStrings("Z", fresh.board.serial.line.slice());
    try std.testing.expectEqual(@as(u32, 2), fresh.board.serial.channels[9].transmitted);
}

test "RA4T1 refuses loading snapshots saved for RA8D2" {
    var ra8d2_saved: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer ra8d2_saved.deinit();
    {
        const src_rig = try Rig.create(&catalog.ra8d2);
        defer src_rig.destroy();
        try file.writeHeader(&ra8d2_saved.writer);
        try section.save(src_rig.board, &ra8d2_saved.writer);
    }

    const dst_rig = try Rig.create(&catalog.ra4t1);
    defer dst_rig.destroy();
    try std.testing.expectError(section.Error.WrongPart, section.load(dst_rig.board, ra8d2_saved.written()));
}
