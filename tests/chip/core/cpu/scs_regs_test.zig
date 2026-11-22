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

test "ICTR reports INTLINESNUM, ignores writes, and exposes Secure vs NS alias" {
    var store = try Store.init(null);
    defer store.deinit();
    var periph = registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    const guest: Guest = .{ .store = &store };
    var state: banked.Banked = .{};
    const cases = [_]struct { lines: u16, expected: u32 }{
        .{ .lines = 0, .expected = 0 },
        .{ .lines = 96, .expected = 2 },
        .{ .lines = 98, .expected = 3 },
        .{ .lines = 480, .expected = 14 },
    };
    for (cases) |c| {
        var bb: BoardBus = .{
            .memory = GuestBus.of(&guest, false),
            .periph = &periph,
            .security = &state,
            .scs = .{ .config = .{ .irq_lines = c.lines }, .has_security = true },
        };
        const b = bb.view();
        state.current = .secure;
        try b.writeWord(memmap.nvic.ictr, 0xDEAD_BEEF);
        try std.testing.expectEqual(c.expected, try b.readWord(memmap.nvic.ictr));
        try std.testing.expectEqual(c.expected, try b.readWord(memmap.nvic.ictr + 0x20000));
        state.current = .non_secure;
        try std.testing.expectEqual(c.expected, try b.readWord(memmap.nvic.ictr));
        try std.testing.expectEqual(@as(u32, 0), try b.readWord(memmap.nvic.ictr + 0x20000));
    }
}

test "has_fpu = false gates CPACR and FPCCR..FPDSCR as RAZ/WI across both banks" {
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
        .scs = .{ .has_security = true, .has_fpu = false },
    };
    const b = bb.view();
    const fp_at = ra8.chip.core.cpu.fpu.scb.address;
    const regs = [_]u32{ fp_at.cpacr, fp_at.fpccr, fp_at.fpcar, fp_at.fpdscr };
    for ([_]banked.State{ .secure, .non_secure }) |sec| {
        state.current = sec;
        for (regs) |reg| {
            try b.writeWord(reg, 0xFFFF_FFFF);
            try b.writeWord(reg + 0x20000, 0xFFFF_FFFF);
            try std.testing.expectEqual(@as(u32, 0), try b.readWord(reg));
            try std.testing.expectEqual(@as(u32, 0), try b.readWord(reg + 0x20000));
        }
    }
}

test "Policy serves read-only M55 ID and MVFR registers through SCS and ignores writes" {
    const scs_regs = ra8.chip.core.cpu.board_bus.scs_regs;
    const id_regs = ra8.chip.periph.id_regs;
    const Profile = ra8.chip.core.cpu.decode.profile.Profile;
    var store = try Store.init(null);
    defer store.deinit();
    const ram: Guest = .{ .store = &store };
    var backing = GuestBus.of(&ram, false);
    const view = backing.view();
    const policy: scs_regs.Policy = .{
        .has_security = true,
        .id = Profile.m55.idBank(true, 8),
    };

    const reads = [_]struct { addr: u32, expect: u32 }{
        .{ .addr = id_regs.addr.id_pfr0, .expect = 0x2000_0030 },
        .{ .addr = id_regs.addr.id_pfr1, .expect = 0x0000_0230 },
        .{ .addr = id_regs.addr.id_isar5, .expect = 0x0000_0000 },
        .{ .addr = id_regs.addr.mvfr0, .expect = 0x1011_0221 },
        .{ .addr = id_regs.addr.mvfr1, .expect = 0x1210_0211 },
    };
    for (reads) |case| {
        try std.testing.expect(try scs_regs.write(policy, view, case.addr, true, &.{ 0xFF, 0xFF, 0xFF, 0xFF }));
        var buf: [4]u8 = @splat(0);
        try std.testing.expect(try scs_regs.read(policy, view, case.addr, true, &buf));
        try std.testing.expectEqual(case.expect, std.mem.readInt(u32, &buf, .little));

        var ns_alias: [4]u8 = @splat(0xAA);
        try std.testing.expect(try scs_regs.read(policy, view, case.addr + 0x0002_0000, false, &ns_alias));
        try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, &ns_alias, .little));
    }
}
