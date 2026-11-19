//! Covers src/chip/core/machine/catalog.zig: RA8D2, RA8P1, generic Cortex-M33
//! and Cortex-M85 machine instances, and unknown-name refusal (RA8EMU-1342).
const ra8 = @import("ra8");
const std = @import("std");

const catalog = ra8.chip.core.machine.catalog;
const cpuid = ra8.chip.periph.cpuid;

test "ra8d2, ra8p1, cortex-m33, and cortex-m85 resolve by exact name and refuse unknown names" {
    try std.testing.expectEqual(&catalog.ra8d2, catalog.find("ra8d2").?);
    try std.testing.expectEqual(&catalog.ra8p1, catalog.find("ra8p1").?);
    try std.testing.expectEqual(&catalog.cortex_m33, catalog.find("cortex-m33").?);
    try std.testing.expectEqual(&catalog.cortex_m85, catalog.find("cortex-m85").?);
    try std.testing.expectEqual(@as(?*const ra8.chip.core.machine.Machine, null), catalog.find("RA8D2"));
    try std.testing.expectEqual(@as(?*const ra8.chip.core.machine.Machine, null), catalog.find("unknown"));
    try std.testing.expectEqual(@as(?*const ra8.chip.core.machine.Machine, null), catalog.find(""));
}

test "ra8d2 and ra8p1 carry M85 primary and M33 secondary cores" {
    for ([_]*const ra8.chip.core.machine.Machine{ &catalog.ra8d2, &catalog.ra8p1 }) |m| {
        try std.testing.expect(m.hasSecond());
        try std.testing.expectEqual(cpuid.cpu0, m.primary().cpuid);
        try std.testing.expectEqual(cpuid.cpu1, m.core(.cpu1).?.cpuid);
        try std.testing.expect(m.primary().has(.v8_1m));
        try std.testing.expect(!m.core(.cpu1).?.has(.v8_1m));
    }
    try std.testing.expect(!catalog.ra8d2.hasNpu());
    try std.testing.expect(catalog.ra8p1.hasNpu());
}

test "cortex-m33 and cortex-m85 are single-core machines without CPU1 or NPU" {
    try std.testing.expect(!catalog.cortex_m33.hasSecond());
    try std.testing.expectEqual(@as(?ra8.chip.core.machine.Core, null), catalog.cortex_m33.core(.cpu1));
    try std.testing.expectEqual(cpuid.word(cpuid.partno.cortex_m33), catalog.cortex_m33.primary().cpuid);
    try std.testing.expect(!catalog.cortex_m33.primary().has(.v8_1m));
    try std.testing.expect(!catalog.cortex_m33.hasNpu());

    try std.testing.expect(!catalog.cortex_m85.hasSecond());
    try std.testing.expectEqual(@as(?ra8.chip.core.machine.Core, null), catalog.cortex_m85.core(.cpu1));
    try std.testing.expectEqual(cpuid.word(cpuid.partno.cortex_m85), catalog.cortex_m85.primary().cpuid);
    try std.testing.expect(catalog.cortex_m85.primary().has(.v8_1m));
    try std.testing.expect(!catalog.cortex_m85.hasNpu());
}

test "findIn matches machine aliases without loosening case or unknown lookup" {
    const Machine = ra8.chip.core.machine.Machine;
    const aliased: Machine = .{
        .name = "sample-mcu",
        .aliases = &.{ "sample-kit-v1", "sample-board" },
        .label = "Sample MCU",
        .cores = .{ .primary = catalog.cortex_m33.primary() },
        .memory = catalog.cortex_m33.memory,
        .part = .ra8d2,
    };
    const entries = [_]*const Machine{&aliased};

    try std.testing.expectEqual(&aliased, catalog.findIn(&entries, "sample-mcu").?);
    try std.testing.expectEqual(&aliased, catalog.findIn(&entries, "sample-kit-v1").?);
    try std.testing.expectEqual(&aliased, catalog.findIn(&entries, "sample-board").?);
    try std.testing.expectEqual(@as(?*const Machine, null), catalog.findIn(&entries, "Sample-Kit-V1"));
    try std.testing.expectEqual(@as(?*const Machine, null), catalog.findIn(&entries, "other"));
}
