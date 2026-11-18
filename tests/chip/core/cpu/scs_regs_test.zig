//! Covers `src/chip/core/cpu/scs_regs.zig`: NVIC/SCB/SysTick/DWT/FPB register
//! masking up to 480 external IRQs and non-multiple-of-32 tail words.
const ra8 = @import("ra8");
const std = @import("std");

const banked = ra8.chip.core.banked;
const BoardBus = ra8.chip.core.cpu.board_bus.BoardBus;
const dwt = ra8.chip.periph.dwt;
const fpb = ra8.chip.periph.fpb;
const Guest = ra8.chip.core.cpu.memory.guest.Guest;
const GuestBus = ra8.chip.core.cpu.memory.guest.bus.GuestBus;
const memmap = ra8.chip.core.memmap;
const nvic = ra8.chip.periph.nvic;
const registry = ra8.chip.periph.registry;
const Store = ra8.chip.core.cpu.memory.store.Store;

test "NVIC ISER, ISPR, IABR, ITNS and IPR enforce non-multiple-of-32 tail masks and 480-line ceiling" {
    var store = try Store.init(null);
    defer store.deinit();
    var periph = registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    const guest: Guest = .{ .store = &store };
    var state: banked.Banked = .{};
    var bb: BoardBus = .{
        .memory = GuestBus.of(&guest, false),
        .periph = &periph,
        .security = &state,
        .scs = .{
            .config = .{ .irq_lines = 98, .prio_bits = 3, .fpb_code = 4, .syst_calib = 0x8000_1234 },
            .systicks = 1,
            .has_security = true,
            .dwt_numcomp = 2,
            .fpb_wired = true,
        },
    };
    const b = bb.view();

    // Word 3 (lines 96..127) allows only bits 0..1 (lines 96..97).
    try b.writeWord(memmap.nvic.iser + 12, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0x0000_0003), try b.readWord(memmap.nvic.iser + 12));
    try b.writeWord(memmap.nvic.iser + 16, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0), try b.readWord(memmap.nvic.iser + 16));

    // ITNS word 3 masks to 0x3; IABR is read-only to firmware and NS-masked by ITNS.
    try b.writeWord(nvic.itns.base + 12, 0xFFFF_FFFE);
    try std.testing.expectEqual(@as(u32, 0x0000_0002), try b.readWord(nvic.itns.base + 12));
    try b.registers().writeWord(memmap.nvic.iabr + 12, 0xFFFF_FFFF);
    try b.writeWord(memmap.nvic.iabr + 12, 0);
    try std.testing.expectEqual(@as(u32, 0x0000_0003), try b.readWord(memmap.nvic.iabr + 12));
    try std.testing.expectEqual(@as(u32, 0x0000_0002), try b.readWord(memmap.nvic.iabr + 12 + 0x20000));

    // IPR word for lines 96..99: lines 96..97 mask to 0xE0, lines 98..99 are RAZ/WI.
    try b.writeWord(memmap.nvic.ipr + 96, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0x0000_E0E0), try b.readWord(memmap.nvic.ipr + 96));
    // NS view of IPR sees only line 97 (ITNS bit 1 == 1).
    try std.testing.expectEqual(@as(u32, 0x0000_E000), try b.readWord(memmap.nvic.ipr + 96 + 0x20000));

    // SHPR1..3 mask priority bytes to 0xE0; systicks == 1 leaves NS SYST RES0.
    try b.writeWord(memmap.scb.shpr1, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0xE0E0_E0E0), try b.readWord(memmap.scb.shpr1));
    try b.writeWord(memmap.scb.shpr2, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0xE000_0000), try b.readWord(memmap.scb.shpr2));
    try std.testing.expectEqual(@as(u32, 0x8000_1234), try b.readWord(memmap.syst.calib));
    try std.testing.expectEqual(@as(u32, 0), try b.readWord(memmap.syst.calib + 0x20000));

    // DWT_CTRL.NUMCOMP and FP_CTRL.NUM_CODE stay read-only across writes.
    try b.writeWord(dwt.base, 1);
    try std.testing.expectEqual(@as(u32, 0x2000_0001), try b.readWord(dwt.base));
    try b.writeWord(fpb.base, fpb.ctrl_bits.key | fpb.ctrl_bits.enable);
    try std.testing.expectEqual(fpb.ctrlValue(true, 4), try b.readWord(fpb.base));
}

test "480 external IRQs address word 14 and IPR byte 479 cleanly" {
    var store = try Store.init(null);
    defer store.deinit();
    var periph = registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    const guest: Guest = .{ .store = &store };
    var bb: BoardBus = .{
        .memory = GuestBus.of(&guest, false),
        .periph = &periph,
        .scs = .{ .config = .{ .irq_lines = 480, .prio_bits = 4 } },
    };
    const b = bb.view();
    try b.writeWord(memmap.nvic.iser + 14 * 4, 0x8000_0000);
    try std.testing.expectEqual(@as(u32, 0x8000_0000), try b.readWord(memmap.nvic.iser + 14 * 4));
    try b.writeWord(memmap.nvic.iser + 15 * 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0), try b.readWord(memmap.nvic.iser + 15 * 4));
    const byte_in = [1]u8{0xAF};
    try b.write(memmap.nvic.ipr + 479, &byte_in);
    var byte_out: [1]u8 = undefined;
    try b.read(memmap.nvic.ipr + 479, &byte_out);
    try std.testing.expectEqual(@as(u8, 0xA0), byte_out[0]);
}
