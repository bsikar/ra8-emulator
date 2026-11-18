//! Covers src/chip/core/machine/core.zig: core capability descriptors built
//! independently of slot number (RA8EMU-1342).
const ra8 = @import("ra8");
const std = @import("std");

const core = ra8.chip.core.machine.core;
const cpuid = ra8.chip.periph.cpuid;

test "Cortex-M85 carries Armv8.1-M, LOB, configurable MVE and its CPUID revision" {
    const full = core.cortexM85(.{
        .security = true,
        .fpu = .double,
        .mve = true,
        .systicks = 2,
        .revision = .{ .variant = 0, .patch = 2 },
    });
    try std.testing.expectEqualStrings("Cortex-M85", full.name);
    try std.testing.expectEqual(@as(u32, 0x410F_D232), full.cpuid);
    try std.testing.expect(full.has(.v8_1m));
    try std.testing.expect(full.has(.mve));
    try std.testing.expect(full.has(.lob));
    try std.testing.expect(full.security);
    try std.testing.expect(full.hasFpu());
    try std.testing.expectEqual(core.Fpu.double, full.fpu);
    try std.testing.expectEqual(@as(u2, 2), full.systicks);

    const scalar = core.cortexM85(.{
        .security = false,
        .fpu = .none,
        .mve = false,
        .systicks = 1,
    });
    try std.testing.expect(scalar.has(.v8_1m));
    try std.testing.expect(!scalar.has(.mve));
    try std.testing.expect(!scalar.mve);
    try std.testing.expect(scalar.has(.lob));
    try std.testing.expect(!scalar.security);
    try std.testing.expect(!scalar.hasFpu());
    try std.testing.expectEqual(@as(u2, 1), scalar.systicks);
}

test "Cortex-M33 reports 0xD21 and omits Armv8.1-M, MVE and LOB" {
    const m33 = core.cortexM33(.{
        .security = true,
        .fpu = .single,
        .systicks = 2,
        .revision = .{ .variant = 0, .patch = 4 },
    });
    try std.testing.expectEqualStrings("Cortex-M33", m33.name);
    try std.testing.expectEqual(@as(u32, 0x410F_D214), m33.cpuid);
    try std.testing.expectEqual(cpuid.partno.cortex_m33, cpuid.part(m33.cpuid));
    try std.testing.expect(m33.has(.base));
    try std.testing.expect(!m33.has(.v8_1m));
    try std.testing.expect(!m33.has(.mve));
    try std.testing.expect(!m33.has(.lob));
    try std.testing.expect(!m33.mve);
    try std.testing.expect(m33.hasFpu());
    try std.testing.expectEqual(core.Fpu.single, m33.fpu);
}

test "Cortex-M33 and Cortex-M85 propagate ScsConfig into Core and Profile" {
    const custom = core.cortexM33(.{
        .security = true,
        .fpu = .none,
        .systicks = 1,
        .scs = .{
            .irq_lines = 98,
            .prio_bits = 3,
            .sau_regions = 0,
            .mpu_regions_s = 4,
            .mpu_regions_ns = 0,
            .dwt_comparators = 2,
            .fpb_code = 4,
            .init_vtor = 0x0800_0000,
            .syst_calib = 0x4000_270F,
        },
    });
    try std.testing.expectEqual(core.Fpu.none, custom.profile.fpu);
    try std.testing.expectEqual(@as(u16, 98), custom.profile.irq_lines);
    try std.testing.expectEqual(@as(u4, 3), custom.profile.prio_bits);
    try std.testing.expectEqual(@as(?u32, 0x0800_0000), custom.profile.init_vtor);
    try std.testing.expectEqual(@as(u8, 4), custom.scs.mpu_regions_s);
}
