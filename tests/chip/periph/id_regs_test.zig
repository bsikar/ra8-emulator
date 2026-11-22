//! Covers src/chip/periph/id_regs.zig.
const ra8 = @import("ra8");
const std = @import("std");

const id_regs = ra8.chip.periph.id_regs;

test "M55 full FPU + MVE-F profile matches TRM ID and MVFR reset values" {
    const bank = id_regs.Bank.fromConfig(.{
        .v8_1m = true,
        .mve = true,
        .mve_fp = true,
        .lob = true,
        .pacbti = false,
        .fpu = .double,
        .fp16 = true,
        .security = true,
    });
    try std.testing.expectEqual(@as(u32, 0x2000_0030), bank.pfr[0]);
    try std.testing.expectEqual(@as(u32, 0x0000_0230), bank.pfr[1]);
    try std.testing.expectEqual(@as(u32, 0x1020_0000), bank.dfr0);
    try std.testing.expectEqual(@as(u32, 0x0000_0000), bank.afr0);
    try std.testing.expectEqualSlices(u32, &.{ 0x0011_1040, 0, 0x0100_0000, 0x0000_0011 }, &bank.mmfr);
    try std.testing.expectEqualSlices(
        u32,
        &.{ 0x0110_3110, 0x0221_2000, 0x2023_2232, 0x0111_1131, 0x0131_0132, 0x0000_0000 },
        &bank.isar,
    );
    try std.testing.expectEqualSlices(u32, &.{ 0x1011_0221, 0x1210_0211, 0x0000_0040 }, &bank.mvfr);
}

test "M55 MVFR combinations match TRM Table 5-3 and HX single+half option" {
    const mve_i_no_fp = id_regs.Bank.fromConfig(.{ .pacbti = false, .fpu = .none, .mve = true });
    try std.testing.expectEqualSlices(u32, &.{ 0x0000_0001, 0x0000_0100, 0 }, &mve_i_no_fp.mvfr);

    const no_fp_no_mve = id_regs.Bank.fromConfig(.{ .pacbti = false, .fpu = .none, .mve = false });
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 0 }, &no_fp_no_mve.mvfr);

    const dp_mve_i = id_regs.Bank.fromConfig(.{ .pacbti = false, .fpu = .double, .mve = true, .mve_fp = false });
    try std.testing.expectEqualSlices(u32, &.{ 0x1011_0221, 0x1210_0111, 0x0000_0040 }, &dp_mve_i.mvfr);

    const dp_no_mve = id_regs.Bank.fromConfig(.{ .pacbti = false, .fpu = .double, .mve = false });
    try std.testing.expectEqualSlices(u32, &.{ 0x1011_0221, 0x1210_0011, 0x0000_0040 }, &dp_no_mve.mvfr);

    const sp_fp16_mve_f = id_regs.Bank.fromConfig(.{
        .pacbti = false,
        .fpu = .single,
        .fp16 = true,
        .mve = true,
        .mve_fp = true,
    });
    try std.testing.expectEqualSlices(u32, &.{ 0x1011_0021, 0x1110_0211, 0x0000_0040 }, &sp_fp16_mve_f.mvfr);
}

test "Security, debug, PACBTI, M33, and sub-word read/covers rules" {
    const no_tz_min_dbg = id_regs.Bank.fromConfig(.{
        .pacbti = false,
        .security = false,
        .halting_debug = false,
        .coproc = true,
        .revidr = 0x5,
    });
    try std.testing.expectEqual(@as(u32, 0x0000_0200), no_tz_min_dbg.pfr[1]);
    try std.testing.expectEqual(@as(u32, 0x1000_0000), no_tz_min_dbg.dfr0);
    try std.testing.expectEqual(@as(u32, 0x0114_3110), no_tz_min_dbg.isar[0]);
    try std.testing.expectEqual(@as(u32, 0x5), no_tz_min_dbg.revidr);

    const m85 = id_regs.Bank.fromConfig(.{ .pacbti = true });
    try std.testing.expectEqual(@as(u32, 0x0010_0000), m85.isar[5]);

    const m33 = id_regs.Bank.fromConfig(.{
        .v8_1m = false,
        .mve = false,
        .mve_fp = false,
        .lob = false,
        .pacbti = false,
        .fpu = .single,
        .fp16 = false,
        .security = true,
        .tcm = false,
        .cache_maint = false,
    });
    try std.testing.expectEqual(@as(u32, 0x0000_0030), m33.pfr[0]);
    try std.testing.expectEqual(@as(u32, 0x0000_0210), m33.pfr[1]);
    try std.testing.expectEqual(@as(u32, 0x0110_1110), m33.isar[0]);
    try std.testing.expectEqual(@as(u32, 0x2023_2132), m33.isar[2]);
    try std.testing.expectEqual(@as(u32, 0), m33.isar[5]);
    try std.testing.expectEqualSlices(u32, &.{ 0x1011_0021, 0x1100_0011, 0x0000_0040 }, &m33.mvfr);

    var word: [4]u8 = undefined;
    try std.testing.expect(m85.read(id_regs.addr.id_isar5, &word));
    try std.testing.expectEqual(@as(u32, 0x0010_0000), std.mem.readInt(u32, &word, .little));
    var byte: [1]u8 = undefined;
    try std.testing.expect(m85.read(id_regs.addr.id_isar5 + 2, &byte));
    try std.testing.expectEqual(@as(u8, 0x10), byte[0]);
    try std.testing.expect(id_regs.Bank.covers(id_regs.addr.mvfr0, 4));
    try std.testing.expect(!id_regs.Bank.covers(id_regs.addr.mvfr0 + 3, 2));
    try std.testing.expect(!m85.read(0xE000_ED00, &word));
}
