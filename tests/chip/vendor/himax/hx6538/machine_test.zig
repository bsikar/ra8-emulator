//! Covers src/chip/vendor/himax/hx6538/machine.zig: dual M55 cores, ID/SCS config,
//! explicit NPU exclusion, shared SRAM/QSPI, private TCM, and bit-28 aliases.
const ra8 = @import("ra8");
const std = @import("std");

const cpuid = ra8.chip.periph.cpuid;
const Guest = ra8.chip.core.cpu.memory.guest.Guest;
const hx = ra8.chip.vendor.himax.hx6538.machine;
const Store = ra8.chip.core.cpu.memory.store.Store;

test "HX6538 configures dual Cortex-M55 cores with WE2 SCS/DWT/FPB limits and no NPU" {
    const m = &hx.machine;
    try std.testing.expectEqualStrings("hx6538", m.name);
    try std.testing.expect(m.hasSecond());
    try std.testing.expect(!m.hasNpu());
    try std.testing.expectEqual(@as(u32, 400_000_000), m.cpu0_hz);
    try std.testing.expectEqual(@as(u32, 150_000_000), m.cpu1_hz);

    for ([_]ra8.chip.core.machine.Core{ m.primary(), m.core(.cpu1).? }) |core| {
        try std.testing.expectEqual(@as(u12, cpuid.partno.cortex_m55), cpuid.part(core.cpuid));
        try std.testing.expect(core.has(.v8_1m));
        try std.testing.expect(core.has(.mve));
        try std.testing.expect(core.has(.lob));
        try std.testing.expect(!core.has(.pacbti));
        try std.testing.expectEqual(@as(u16, 224), core.scs.irq_lines);
        try std.testing.expectEqual(@as(u4, 3), core.scs.prio_bits);
        try std.testing.expectEqual(@as(u4, 4), core.dwtComparators());
        try std.testing.expectEqual(@as(u5, 8), core.scs.fpb_code);
        try std.testing.expectEqual(@as(u8, 8), core.scs.sau_regions);
    }
}

test "HX6538 Store maps bit-28 aliases, keeps ITCM/DTCM private, and shares SRAM across cores" {
    var cpu0 = try Store.initFor(null, &hx.memory_map);
    defer cpu0.deinit();
    var cpu1 = try Store.init(&cpu0);
    defer cpu1.deinit();
    const g0: Guest = .{ .store = &cpu0 };
    const g1: Guest = .{ .store = &cpu1 };

    // ITCM and DTCM are core-private with bit-28 Secure aliases.
    try g0.writeWord(0x0000_0020, 0x1111_2222);
    try g1.writeWord(0x1000_0020, 0x3333_4444);
    try std.testing.expectEqual(@as(u32, 0x1111_2222), try g0.readWord(0x1000_0020));
    try std.testing.expectEqual(@as(u32, 0x3333_4444), try g1.readWord(0x0000_0020));

    try g0.writeWord(0x3000_0040, 0xAAAA_5555);
    try std.testing.expectEqual(@as(u32, 0xAAAA_5555), try g0.readWord(0x2000_0040));
    try std.testing.expectEqual(@as(u32, 0), try g1.readWord(0x2000_0040));

    // SRAM0..2 are shared across CM55M and CM55S across bit-28 aliases.
    try g0.writeWord(0x3400_0100, 0xDEAD_C0DE);
    try std.testing.expectEqual(@as(u32, 0xDEAD_C0DE), try g1.readWord(0x2400_0100));
    try g1.writeWord(0x2410_0100, 0xBEEF_F00D);
    try std.testing.expectEqual(@as(u32, 0xBEEF_F00D), try g0.readWord(0x3410_0100));
    try g0.writeWord(0x3600_0200, 0xCAFE_1234);
    try std.testing.expectEqual(@as(u32, 0xCAFE_1234), try g1.readWord(0x2600_0200));

    // BootROM & QSPI are read-only on normal stores and fault outside mapped space.
    try std.testing.expectError(error.Unmapped, g0.write(0x2A00_0000, &.{ 1, 2, 3, 4 }));
    try std.testing.expectError(error.Unmapped, g0.readWord(0x2430_0000));
}
