//! The board's non-CPU initiators meter the fabric through their wired
//! guest (RA8EMU-1041): a real DMAC copy and a DTC activation through the
//! boundary land their bytes, stalls and pending contention on their own
//! timed port, and the setup traffic around them stays unmetered.
const std = @import("std");
const ra8 = @import("ra8");
const memmap = ra8.chip.core.memmap;
const dmac = ra8.chip.periph.dmac;
const dma_bank = ra8.chip.periph.dma_bank;
const dtc = ra8.chip.periph.dtc;
const xfer = ra8.chip.periph.dtc.xfer;
const icu = ra8.chip.periph.icu;
const backing = ra8.board.external.backing;
const Store = ra8.chip.core.cpu.memory.store.Store;
const Guest = ra8.chip.core.cpu.memory.guest.Guest;

const source_at: u32 = memmap.sdram_base + 0x100;
/// A byte copy, both addresses incrementing, interrupt on the last transfer.
const byte_copy: u32 = (@as(u32, 0b0000_1000) << 24) | (@as(u32, 0b0000_1000) << 16);
const dest_at: u32 = memmap.sdram_base + 0x200;

/// One board whose CPU0 store carries the external fabric, with every
/// bus initiator wired through its own timed port.
const Rig = struct {
    board: ra8.board.board.Board,
    external: backing.Backing,
    store: Store,

    fn open(self: *Rig) !void {
        self.board = ra8.board.board.Board.init(std.testing.allocator);
        errdefer self.board.deinit();
        var config = ra8.board.external.memory.Config{};
        config.ospi.size = 1024 * 1024;
        config.sdram.size = 1024 * 1024;
        self.external = try backing.Backing.init(try ra8.board.external.memory.Layout.init(config), self.board.nor.window());
        errdefer self.external.deinit();
        self.store = try Store.init(null);
        errdefer self.store.deinit();
        self.store.attachExternal(self.external.port());
        // The board's blocks hold pointers into it, so this runs in place
        // and nothing copies the board after wiring.
        try ra8.board.wiring.attachBlocks(&self.board, .{ .store = &self.store });
    }

    fn memory(self: *Rig) Guest {
        return .{ .store = &self.store };
    }

    /// Release in the reverse of the order `open` built them.
    fn close(self: *Rig) void {
        self.store.deinit();
        self.external.deinit();
        self.board.deinit();
    }

    fn byteAt(self: *Rig, address: u32) !u8 {
        var cell: [1]u8 = undefined;
        try self.memory().read(address, &cell);
        return cell[0];
    }
};

fn at(offset: u32) u32 {
    return dmac.channelAddress(0) + offset;
}

test "a real DMAC copy meters the fabric on the dmac port, not the cpu's" {
    var rig: Rig = undefined;
    try rig.open();
    defer rig.close();
    try rig.memory().write(source_at, &.{ 0xA0, 0xA1, 0xA2, 0xA3 });
    rig.board.dma_module.write(dma_bank.win_base, 1, dma_bank.field.dmst);
    rig.board.dma.write(at(dmac.off.dmsar), 4, source_at);
    rig.board.dma.write(at(dmac.off.dmdar), 4, dest_at);
    rig.board.dma.write(at(dmac.off.dmcra), 4, 4);
    rig.board.dma.write(at(dmac.off.dmtmd), 2, 0);
    rig.board.dma.write(at(dmac.off.dmamd), 2, 2 << dmac.xfer.field.sm_shift | 2 << dmac.xfer.field.dm_shift);
    rig.board.dma.write(at(dmac.off.dmcnt), 1, dmac.field.dte);
    for (0..4) |_| rig.board.dma.write(at(dmac.off.dmreq), 1, dmac.field.swreq);
    try std.testing.expectEqual(@as(u8, 0xA3), try rig.byteAt(dest_at + 3));
    const fabric = backing.fabricOf(&rig.store).?;
    const counters = fabric.counters(.sdram, 0);
    try std.testing.expectEqual(@as(u64, 4), counters.bytes_read);
    try std.testing.expectEqual(@as(u64, 4), counters.bytes_written);
    try std.testing.expect(counters.stall_cycles_by_initiator[ra8.chip.core.cpu.memory.initiator.Initiator.dmac.timedIndex().?] > 0);
    try std.testing.expect(fabric.takePending(.dmac) > 0);
    try std.testing.expectEqual(@as(u64, 0), counters.cpu_stall_cycles);
}

test "a DTC activation through the boundary meters the dtc0 port" {
    var rig: Rig = undefined;
    try rig.open();
    defer rig.close();
    const vector_base: u32 = memmap.sram_base;
    const ti_at: u32 = memmap.sram_base + 0x100;
    const event: u16 = 0x0CC;
    const slot: usize = 7;
    try rig.memory().write(source_at, &.{0x5A});
    rig.board.transfers.write(dtc.win_base + dtc.off.dtcvbr, 4, vector_base);
    rig.board.transfers.write(dtc.win_base + dtc.off.dtcst, 1, dtc.field.start);
    const entry = dtc.entryAddress(vector_base, slot);
    try rig.memory().writeWord(entry, ti_at);
    try rig.memory().writeWord(ti_at + xfer.off.mr, byte_copy);
    try rig.memory().writeWord(ti_at + xfer.off.sar, source_at);
    try rig.memory().writeWord(ti_at + xfer.off.dar, dest_at);
    try rig.memory().writeWord(ti_at + xfer.off.counts, @as(u32, 1) << 16);
    rig.board.events.write(icu.slotAddress(slot), 4, event | icu.field.dtce);
    try rig.board.raise(rig.memory(), event);
    try std.testing.expectEqual(@as(u8, 0x5A), try rig.byteAt(dest_at));
    const fabric = backing.fabricOf(&rig.store).?;
    const counters = fabric.counters(.sdram, 0);
    try std.testing.expectEqual(@as(u64, 1), counters.bytes_read);
    try std.testing.expectEqual(@as(u64, 1), counters.bytes_written);
    try std.testing.expect(counters.stall_cycles_by_initiator[ra8.chip.core.cpu.memory.initiator.Initiator.dtc0.timedIndex().?] > 0);
    try std.testing.expect(fabric.takePending(.dtc0) > 0);
    try std.testing.expectEqual(@as(u64, 0), counters.cpu_stall_cycles);
}
