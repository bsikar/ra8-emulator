//! Covers src/chip/vendor/renesas/ra8e1/ra8e1.zig: single-core Cortex-M85 r0p2 CPUID,
//! SCS capabilities, memory and bit-28 NS alias map, Factory/Option Flash,
//! IDAU regions, peripheral resets, and fault behavior on absent RA8D2 blocks.
const ra8 = @import("ra8");
const std = @import("std");

const Board = ra8.board.board.Board;
const catalog = ra8.chip.core.machine.catalog;
const core_clock = ra8.board.core_clock;
const cpuid = ra8.chip.periph.cpuid;
const fcache = ra8.chip.vendor.renesas.ra8e1.fcache;
const gpio = ra8.chip.periph.gpio;
const Guest = ra8.chip.core.cpu.memory.guest.Guest;
const icu = ra8.chip.periph.icu;
const oscsf = ra8.chip.periph.oscsf;
const pfs = ra8.chip.periph.pfs;
const prcr = ra8.chip.periph.prcr;
const ra8e1 = ra8.chip.vendor.renesas.ra8e1;
const sau_attr = ra8.chip.periph.sau.attribution;
const Store = ra8.chip.core.cpu.memory.store.Store;
const sysclk = ra8.chip.periph.sysclk;
const wiring = ra8.board.wiring;

fn expectSharedRw(guest: Guest, s_addr: u32, ns_addr: u32, value: u32) !void {
    try guest.writeWord(s_addr, value);
    try std.testing.expectEqual(value, try guest.readWord(ns_addr));
    try guest.writeWord(ns_addr, value ^ 0xA5A5_5A5A);
    try std.testing.expectEqual(value ^ 0xA5A5_5A5A, try guest.readWord(s_addr));
}

fn expectSharedRo(guest: Guest, s_addr: u32, ns_addr: u32) !void {
    try std.testing.expectEqual(try guest.readWord(s_addr), try guest.readWord(ns_addr));
    try std.testing.expectError(error.Unmapped, guest.writeWord(s_addr, 0x1122_3344));
    try std.testing.expectError(error.Unmapped, guest.writeWord(ns_addr, 0x1122_3344));
}

fn allocBoard(machine: *const ra8.chip.core.machine.Machine) !*Board {
    const board = try std.testing.allocator.create(Board);
    board.* = Board.init(std.testing.allocator);
    board.machine = machine;
    return board;
}

fn freeBoard(board: *Board) void {
    board.deinit();
    std.testing.allocator.destroy(board);
}

test "ra8e1 descriptor matches RA8E1 / Cortex-M85 r0p2 hardware" {
    const m = catalog.find("ra8e1") orelse return error.MissingMachine;
    try std.testing.expectEqual(&catalog.ra8e1, m);
    try std.testing.expectEqual(&catalog.ra8e1, catalog.find("fpb-ra8e1").?);
    try std.testing.expectEqualStrings("ra8e1", m.name);
    try std.testing.expectEqualStrings("RA8E1", m.label);
    try std.testing.expectEqual(@as(usize, 1), m.aliases.len);
    try std.testing.expectEqualStrings("fpb-ra8e1", m.aliases[0]);
    try std.testing.expect(!m.hasSecond());
    try std.testing.expect(!m.hasNpu());
    try std.testing.expectEqual(@as(?ra8.chip.core.machine.Core, null), m.core(.cpu1));

    const c0 = m.primary();
    try std.testing.expectEqual(@as(u32, 0x410F_D232), c0.cpuid);
    try std.testing.expectEqual(cpuid.partno.cortex_m85, cpuid.part(c0.cpuid));
    try std.testing.expect(c0.security);
    try std.testing.expectEqual(ra8.chip.core.machine.core.Fpu.double, c0.fpu);
    try std.testing.expect(c0.mve);
    try std.testing.expectEqual(@as(u2, 2), c0.systicks);
    try std.testing.expectEqual(@as(u16, 96), c0.scs.irq_lines);
    try std.testing.expectEqual(@as(u4, 4), c0.scs.prio_bits);
    try std.testing.expectEqual(@as(u8, 8), c0.scs.sau_regions);
    try std.testing.expectEqual(@as(u8, 8), c0.scs.mpu_regions_s);
    try std.testing.expectEqual(@as(u8, 8), c0.scs.mpu_regions_ns);
    try std.testing.expectEqual(@as(?u4, 8), c0.scs.dwt_comparators);
    try std.testing.expectEqual(@as(u5, 8), c0.scs.fpb_code);
    try std.testing.expectEqual(@as(?u32, 0x0200_0000), c0.scs.init_vtor);
    try std.testing.expectEqual(@as(u32, 0x0000_270F), c0.scs.syst_calib);
}

test "memory map, bit-28 NS aliases, Factory PNR0..3, Option Flash, and gaps" {
    const m = &catalog.ra8e1;
    var store = try Store.initFor(null, m.memory);
    defer store.deinit();
    const board = try allocBoard(m);
    defer freeBoard(board);
    const guest: Guest = .{ .store = &store, .initiator = .cpu0 };
    try wiring.attachBlocks(board, guest);

    try expectSharedRw(guest, 0x0000_0000, 0x1000_0000, 0x1122_3344);
    try expectSharedRw(guest, 0x2000_0000, 0x3000_0000, 0x5566_7788);
    try expectSharedRw(guest, 0x2206_0000, 0x3206_0000, 0xDEAD_BEEF);
    try expectSharedRw(guest, 0x2600_0000, 0x3600_0000, 0xCAFE_BABE);

    try guest.program(0x0200_0000, &.{ 0x78, 0x56, 0x34, 0x12 });
    try expectSharedRo(guest, 0x0200_0000, 0x1200_0000);
    try expectSharedRo(guest, 0x2700_0000, 0x3700_0000);

    var pnr: [16]u8 = undefined;
    try guest.read(0x0300_80F0, &pnr);
    try std.testing.expectEqualStrings("R7FA8E1AFDCFB   ", &pnr);
    var pnr_ns: [16]u8 = undefined;
    try guest.read(0x1300_80F0, &pnr_ns);
    try std.testing.expectEqualSlices(u8, &pnr, &pnr_ns);
    try std.testing.expectEqual(@as(u32, 0x4146_3752), try guest.readWord(0x0300_80F0));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), try guest.readWord(0x0300_A100));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), try guest.readWord(0x1300_A180));
    try std.testing.expectEqual(@as(u32, 0x0000_0000), try guest.readWord(0x0300_A280));
    try std.testing.expectEqual(@as(u32, 0x0000_0000), try guest.readWord(0x0300_A290));
    try std.testing.expectEqual(@as(u32, 0x0000_0000), try guest.readWord(0x0300_A2C0));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), try guest.readWord(0x2703_0380));
    try std.testing.expectEqual(@as(u32, 0x0000_0000), try guest.readWord(0x2703_03C0));

    const gaps = [_]u32{
        0x0000_4000, 0x0210_0000, 0x2000_4000, 0x2200_0000,
        0x220E_0000, 0x2600_0400, 0x2700_3000, 0x6800_0000,
        0x8000_0000,
    };
    for (gaps) |addr| {
        try std.testing.expectError(error.Unmapped, guest.readWord(addr));
        try std.testing.expectError(error.Unmapped, guest.writeWord(addr, 1));
    }
}

test "IDAU partition follows R01UH1129EJ0110 Fig. 40.5 regions 0..6 and PPB exempt" {
    const cases = [_]struct { addr: u32, state: sau_attr.State, region: u8, exempt: bool }{
        .{ .addr = 0x0200_0000, .state = .callable, .region = 0, .exempt = false },
        .{ .addr = 0x1200_0000, .state = .non_secure, .region = 1, .exempt = false },
        .{ .addr = 0x2206_0000, .state = .callable, .region = 2, .exempt = false },
        .{ .addr = 0x3206_0000, .state = .non_secure, .region = 3, .exempt = false },
        .{ .addr = 0x4001_E000, .state = .secure, .region = 4, .exempt = false },
        .{ .addr = 0x5001_E000, .state = .non_secure, .region = 5, .exempt = false },
        .{ .addr = 0x8000_0000, .state = .non_secure, .region = 6, .exempt = false },
        .{ .addr = 0xE000_ED00, .state = .non_secure, .region = 7, .exempt = true },
    };
    for (cases) |c| {
        const got = ra8e1.idauAnswer(null, c.addr);
        try std.testing.expectEqual(c.state, got.state);
        try std.testing.expectEqual(@as(?u8, c.region), got.region);
        try std.testing.expectEqual(c.exempt, got.exempt);
    }
}

test "on-chip peripherals expose RA8E1 resets and fault on absent RA8D2 blocks" {
    var store = try Store.initFor(null, catalog.ra8e1.memory);
    defer store.deinit();
    const board = try allocBoard(&catalog.ra8e1);
    defer freeBoard(board);
    try wiring.attachBlocks(board, .{ .store = &store });

    try std.testing.expectEqual(
        @as(?u32, 0x01),
        board.bus.tryRead(sysclk.win_base + sysclk.regs.sckscr, 1),
    );
    try std.testing.expectEqual(
        @as(?u32, 0x01),
        board.bus.tryRead(oscsf.win_base + oscsf.regs.hococr, 1),
    );
    try std.testing.expectEqual(
        @as(?u32, 0x07),
        board.bus.tryRead(oscsf.win_base + oscsf.regs.hococr2, 1),
    );
    try std.testing.expectEqual(
        @as(?u32, 0x00),
        board.bus.tryRead(oscsf.win_base + oscsf.regs.oscsf, 1),
    );

    try std.testing.expect(board.bus.tryWrite(prcr.win_base, 2, prcr.unlockWord(prcr.group.cgc)));
    try std.testing.expect(board.bus.tryWrite(oscsf.win_base + oscsf.regs.hococr, 1, 0x00));
    try std.testing.expectEqual(
        @as(?u32, 0x01),
        board.bus.tryRead(oscsf.win_base + oscsf.regs.oscsf, 1),
    );
    try std.testing.expectEqual(@as(u64, 48_000_000), core_clock.inputs(board).hoco_hz);
    try std.testing.expect(board.bus.tryWrite(0x5001_E3FE, 2, prcr.unlockWord(prcr.group.lpm)));
    try std.testing.expectEqual(@as(?u32, prcr.group.lpm), board.bus.tryRead(0x5001_E3FE, 2));

    try std.testing.expect(board.bus.tryWrite(fcache.win_base + fcache.off.flwt, 1, 0x04));
    try std.testing.expectEqual(@as(?u32, 0x04), board.bus.tryRead(fcache.win_base + fcache.off.flwt, 1));
    try std.testing.expectEqual(@as(?u32, 0xFFB7_7FFC), board.bus.tryRead(0x4020_3000, 4));
    try std.testing.expect(board.pins.pinLevel(0, 9));
    try std.testing.expect(!board.pins.pinLevel(0, 8));

    try std.testing.expectEqual(@as(?u32, 0x0000_0010), board.bus.tryRead(pfs.Pfs.pinAddress(2, 1), 4));
    try std.testing.expectEqual(@as(?u32, 0x0001_0410), board.bus.tryRead(pfs.Pfs.pinAddress(2, 10), 4));
    try std.testing.expectEqual(@as(?u32, 0x1301_0000), board.bus.tryRead(pfs.Pfs.pinAddress(8, 15), 4));
    try std.testing.expect(board.bus.tryRead(icu.win_base + 95 * 4, 4) != null);
    try std.testing.expectEqual(@as(?u32, null), board.bus.tryRead(icu.win_base + 96 * 4, 4));
    try std.testing.expect(board.bus.tryWrite(0x4000_6010, 1, 0xFF));
    try std.testing.expectEqual(@as(?u32, 0xB1), board.bus.tryRead(0x4000_6010, 1));
    try std.testing.expect(board.bus.tryRead(0x4032_2000, 4) != null);
    try std.testing.expect(board.bus.tryRead(0x4032_2A00, 4) != null);
    try std.testing.expect(board.modules.ra8e1);
    try std.testing.expect(board.modules.stopped(0x4032_2500));
    try std.testing.expect(board.bus.tryWrite(0x4020_3010, 4, ~(@as(u32, 1) << 26)));
    try std.testing.expect(!board.modules.stopped(0x4032_2500));
    try std.testing.expect(board.modules.stopped(0x4032_2400));

    const absent = [_]u32{
        0x4000_6014, // IRQCR16
        0x4032_2600, // GPT6
        0x4033_8000, // ADC_B
        0x4035_8500, // SCI5
        0x4035_8800, // SCI8
        0x4040_0140, // PORT10
        0x4040_0A80, // PFS10
        0x4012_0000, // MACI
        0x4013_E000, // MRAM
        0x4014_0000, // NPU
        0x4002_0000, // IPC
        0x4000_F000, // CPU_CTRL
        0x4000_6040, // INTSELR
        0x4044_4000, // DRW
        0x4034_2000, // GLCDC
        0x4035_F000, // I3C
        0x4035_1000, // USBHS
        0x403C_0000, // ETH
    };
    for (absent) |addr| {
        try std.testing.expectEqual(@as(?u32, null), board.bus.tryRead(addr, 4));
    }
    _ = gpio;
}
