//! Covers src/chip/core/machine/core.zig: core capability descriptors built
//! independently of slot number (RA8EMU-1342).
const ra8 = @import("ra8");
const std = @import("std");

const core = ra8.chip.core.machine.core;
const cpuid = ra8.chip.periph.cpuid;
const scs = core.scs;

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

test "cortexM55 builds distinct configurable M55 core without PACBTI" {
    const full = core.cortexM55(.{ .security = true, .fpu = .double, .systicks = 2 });
    try std.testing.expectEqualStrings("Cortex-M55", full.name);
    try std.testing.expectEqual(cpuid.partno.cortex_m55, cpuid.part(full.cpuid));
    try std.testing.expectEqual(@as(u32, 0x411F_D221), full.cpuid);
    try std.testing.expect(full.has(.v8_1m));
    try std.testing.expect(full.has(.mve));
    try std.testing.expect(full.has(.lob));
    try std.testing.expect(!full.has(.pacbti));
    try std.testing.expect(!full.hasPacBti());
    try std.testing.expect(full.hasFpu());
    try std.testing.expectEqual(@as(u4, 4), full.dwtComparators());
    try std.testing.expectEqual(@as(u32, 0), full.idBank().isar[5]);

    const sdk_style = core.cortexM55(.{
        .security = true,
        .fpu = .double,
        .systicks = 2,
        .revision = .{ .variant = 0, .patch = 1 },
        .scs = .{ .prio_bits = 3, .dwt_comparators = 4, .fpb_code = 8, .sau_regions = 8 },
    });
    try std.testing.expectEqual(@as(u32, 0x410F_D221), sdk_style.cpuid);
    try std.testing.expectEqual(@as(u8, 0xE0), sdk_style.profile.prioMask());
    try std.testing.expectEqual(@as(u8, 8), sdk_style.scs.effectiveSau(true));

    const minimal = core.cortexM55(.{
        .security = false,
        .fpu = .none,
        .mve = false,
        .lob = false,
        .cache = false,
        .systicks = 1,
        .scs = .{ .dwt_comparators = 2, .fpb_code = 4, .mpu_regions_s = 4, .sau_regions = 8 },
    });
    try std.testing.expect(!minimal.hasFpu());
    try std.testing.expect(!minimal.has(.mve));
    try std.testing.expect(!minimal.has(.lob));
    try std.testing.expectEqual(@as(u4, 2), minimal.dwtComparators());
    try std.testing.expectEqual(@as(u8, 0), minimal.scs.effectiveSau(false));
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 0 }, &minimal.idBank().mvfr);
}

test "effectiveDwtFor uses M55 CPUID default 4 and preserves explicit override" {
    const def: scs.ScsConfig = .{};
    const m55 = core.cortexM55(.{ .security = true, .fpu = .single, .systicks = 2 });
    const m85 = core.cortexM85(.{ .security = true, .fpu = .double, .systicks = 2 });
    const m33 = core.cortexM33(.{ .security = true, .fpu = .single, .systicks = 2 });
    try std.testing.expectEqual(@as(u4, 4), def.effectiveDwtFor(m55.cpuid));
    try std.testing.expectEqual(@as(u4, 8), def.effectiveDwtFor(m85.cpuid));
    try std.testing.expectEqual(@as(u4, 4), def.effectiveDwtFor(m33.cpuid));

    const eight_dwt: scs.ScsConfig = .{ .dwt_comparators = 8 };
    try std.testing.expectEqual(@as(u4, 8), eight_dwt.effectiveDwtFor(m55.cpuid));
}

test "cortexM55 applies configurable MPU (0..16), SAU (0..8), DWT (2/4/8), and FPB (4/8) defaults" {
    const mpu = ra8.chip.periph.mpu;
    const fpb = ra8.chip.periph.fpb;
    const sau = ra8.chip.periph.sau;
    const m55_cfg = core.cortexM55(.{
        .security = true,
        .fpu = .single,
        .systicks = 2,
        .scs = .{
            .irq_lines = 128,
            .prio_bits = 3,
            .sau_regions = 4,
            .mpu_regions_s = 12,
            .mpu_regions_ns = 16,
            .dwt_comparators = 2,
            .fpb_code = 4,
        },
    });
    var mpu_s = mpu.Mpu.init();
    var mpu_ns = mpu.Mpu.init();
    var sau_unit = sau.Sau.init();
    mpu_s.setRegions(m55_cfg.scs.mpu_regions_s);
    mpu_ns.setRegions(m55_cfg.scs.mpu_regions_ns);
    sau_unit.setRegions(m55_cfg.scs.effectiveSau(m55_cfg.security));
    try std.testing.expectEqual(@as(u32, 12 << 8), mpu_s.typeValue());
    try std.testing.expectEqual(@as(u32, 16 << 8), mpu_ns.typeValue());
    try std.testing.expectEqual(@as(u32, 4), sau_unit.typeValue());
    try std.testing.expectEqual(@as(u4, 2), m55_cfg.dwtComparators());
    try std.testing.expectEqual(@as(u32, 0x1000_0040), fpb.ctrlReset(m55_cfg.scs.fpb_code));

    const default_m55 = core.cortexM55(.{ .security = true, .fpu = .double, .systicks = 2 });
    try std.testing.expectEqual(@as(u4, 4), default_m55.dwtComparators());
    try std.testing.expectEqual(@as(u5, 8), default_m55.scs.fpb_code);
    try std.testing.expectEqual(@as(u8, 8), default_m55.scs.effectiveSau(true));
    try std.testing.expectEqual(@as(u8, 8), default_m55.scs.mpu_regions_s);
}
