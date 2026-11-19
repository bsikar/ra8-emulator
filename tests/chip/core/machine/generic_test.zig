//! Covers src/chip/core/machine/generic.zig: generic Cortex-M33 and
//! Cortex-M85 machine layouts, overrides, and fixture execution.
const std = @import("std");
const ra8 = @import("ra8");

const catalog = ra8.chip.core.machine.catalog;
const cpuid = ra8.chip.periph.cpuid;
const generic = ra8.chip.core.machine.generic;
const harness_mod = ra8.session.harness;
const memmap = ra8.chip.core.memmap;
const symbols = ra8.session.symbols;

const m33_elf = @embedFile("../../../fixtures/generic_machines/cortex_m33.elf");
const m85_elf = @embedFile("../../../fixtures/generic_machines/cortex_m85.elf");
const state_addr: u32 = 0x2000_0100;

fn readWords(guest: ra8.chip.core.cpu.memory.guest.Guest, base: u32, comptime n: usize) ![n]u32 {
    var out: [n]u32 = undefined;
    for (0..n) |i| {
        const offset: u32 = @intCast(i * 4);
        out[i] = try guest.readWord(base + offset);
    }
    return out;
}

fn runToPark(bytes: []const u8, machine: *const ra8.chip.core.machine.Machine) !struct {
    words: [8]u32,
    itm: []u8,
} {
    var h = try harness_mod.open(std.testing.allocator, std.testing.io, .{
        .elf_bytes = bytes,
        .machine = machine,
        .history_frames = 4,
    });
    defer h.deinit();

    const park = symbols.addressOf(h.image(), "generic_park") orelse return error.MissingSymbol;
    _ = try h.session().setBreakpoint(.cpu0, .{ .address = park });
    try h.session().setRunBudget(.cpu0, 200_000);
    const ended = try h.session().run(.cpu0, .cont);
    try std.testing.expect(ended == .stop and ended.stop == .breakpoint);

    const words = try readWords(h.guest(), state_addr, 8);
    const text = (try h.session().itmPort(.cpu0)).output();
    return .{
        .words = words,
        .itm = try std.testing.allocator.dupe(u8, text),
    };
}

test "generic cortex-m33 and cortex-m85 defaults describe single-core profiles" {
    const m33 = generic.cortex_m33;
    try std.testing.expectEqualStrings("cortex-m33", m33.name);
    try std.testing.expectEqualStrings("Cortex-M33", m33.label);
    try std.testing.expect(!m33.hasSecond());
    try std.testing.expectEqual(@as(?ra8.chip.core.machine.Core, null), m33.core(.cpu1));
    try std.testing.expect(!m33.hasNpu());
    try std.testing.expectEqual(cpuid.word(cpuid.partno.cortex_m33), m33.primary().cpuid);
    try std.testing.expectEqual(ra8.chip.core.machine.core.Fpu.single, m33.primary().fpu);
    try std.testing.expect(!m33.primary().has(.v8_1m));
    try std.testing.expect(m33.primary().hasFpu());
    try std.testing.expect(!m33.primary().has(.mve));
    try std.testing.expectEqual(@as(u2, 1), m33.primary().systicks);
    try std.testing.expectEqual(@as(u32, 0), m33.primary().scs.init_vtor.?);
    try std.testing.expectEqual(@as(u4, 0), m33.primary().scs.sau_regions);
    try std.testing.expectEqual(@as(u4, 4), m33.primary().scs.dwt_comparators);

    const m85 = generic.cortex_m85;
    try std.testing.expectEqualStrings("cortex-m85", m85.name);
    try std.testing.expectEqualStrings("Cortex-M85", m85.label);
    try std.testing.expect(!m85.hasSecond());
    try std.testing.expectEqual(@as(?ra8.chip.core.machine.Core, null), m85.core(.cpu1));
    try std.testing.expect(!m85.hasNpu());
    try std.testing.expectEqual(cpuid.word(cpuid.partno.cortex_m85), m85.primary().cpuid);
    try std.testing.expectEqual(ra8.chip.core.machine.core.Fpu.double, m85.primary().fpu);
    try std.testing.expect(m85.primary().has(.v8_1m));
    try std.testing.expect(m85.primary().hasFpu());
    try std.testing.expect(m85.primary().has(.mve));
    try std.testing.expectEqual(@as(u2, 1), m85.primary().systicks);
    try std.testing.expectEqual(@as(u32, 0), m85.primary().scs.init_vtor.?);
    try std.testing.expectEqual(@as(u4, 8), m85.primary().scs.dwt_comparators);
}

test "generic regionsFor and memoryMap expose flash, sram, and ppb without vendor blocks" {
    const map = generic.memoryMap(.{});
    try std.testing.expectEqual(@as(usize, 3), map.regions.len);
    try std.testing.expectEqual(@as(usize, 0), map.aliases.len);
    try std.testing.expectEqual(@as(usize, 0), map.mmio.len);
    try std.testing.expectEqual(ra8.chip.core.machine.memory.UnknownMmio.fault, map.unknown_mmio);
    try std.testing.expect(!map.attach_ra8_blocks);
    try std.testing.expect(!map.has_external);
    try std.testing.expect(!map.allow_extra_pages);

    const flash = map.regionByRole(.flash).?;
    try std.testing.expectEqualStrings("FLASH", flash.name);
    try std.testing.expectEqual(@as(u32, 0x0000_0000), flash.base);
    try std.testing.expectEqual(@as(u32, 256 * 1024), flash.size);
    try std.testing.expect(flash.perms.read and !flash.perms.write and flash.perms.exec);
    try std.testing.expect(flash.track_code);

    const sram = map.regionByRole(.sram).?;
    try std.testing.expectEqualStrings("SRAM", sram.name);
    try std.testing.expectEqual(@as(u32, 0x2000_0000), sram.base);
    try std.testing.expectEqual(@as(u32, 64 * 1024), sram.size);
    try std.testing.expect(sram.perms.read and sram.perms.write and sram.perms.exec);
    try std.testing.expect(!sram.shared);
    try std.testing.expect(sram.track_code);

    const ppb = map.regionByRole(.ppb).?;
    try std.testing.expectEqualStrings("PPB", ppb.name);
    try std.testing.expectEqual(memmap.ppb_base, ppb.base);
    try std.testing.expectEqual(memmap.ppb_size, ppb.size);
    try std.testing.expect(ppb.perms.read and ppb.perms.write and !ppb.perms.exec);
}

test "custom generic Layout and config overrides update memory map and VTOR" {
    const custom_layout = generic.Layout{
        .flash_base = 0x0800_0000,
        .flash_size = 512 * 1024,
        .sram_base = 0x2400_0000,
        .sram_size = 128 * 1024,
    };
    const m33 = generic.cortexM33Machine(.{
        .name = "m33-custom",
        .label = "M33 Custom",
        .layout = custom_layout,
        .fpu = .none,
        .systicks = 2,
    });
    const m85 = generic.cortexM85Machine(.{
        .name = "m85-custom",
        .label = "M85 Custom",
        .layout = custom_layout,
        .fpu = .single,
        .mve = false,
    });

    try std.testing.expectEqualStrings("m33-custom", m33.name);
    try std.testing.expectEqualStrings("M33 Custom", m33.label);
    try std.testing.expectEqual(@as(u32, 0x0800_0000), m33.primary().scs.init_vtor.?);
    try std.testing.expectEqual(@as(u2, 2), m33.primary().systicks);
    try std.testing.expect(!m33.primary().hasFpu());
    try std.testing.expectEqual(@as(u32, 0x0800_0000), m33.memory.regionByRole(.flash).?.base);
    try std.testing.expectEqual(@as(u32, 512 * 1024), m33.memory.regionByRole(.flash).?.size);
    try std.testing.expectEqual(@as(u32, 0x2400_0000), m33.memory.regionByRole(.sram).?.base);
    try std.testing.expectEqual(@as(u32, 128 * 1024), m33.memory.regionByRole(.sram).?.size);

    try std.testing.expectEqualStrings("m85-custom", m85.name);
    try std.testing.expectEqual(@as(u32, 0x0800_0000), m85.primary().scs.init_vtor.?);
    try std.testing.expectEqual(ra8.chip.core.machine.core.Fpu.single, m85.primary().fpu);
    try std.testing.expect(!m85.primary().has(.mve));
}

test "generic cortex-m33 firmware reaches generic_park with expected state and ITM output" {
    const run = try runToPark(m33_elf, &catalog.cortex_m33);
    defer std.testing.allocator.free(run.itm);

    try std.testing.expectEqualSlices(u32, &.{
        0x474D_3333,
        0x410F_D210,
        0x0000_0000,
        0x0004_0008,
        4,
        10,
        0x4108_0000,
        1,
    }, &run.words);
    try std.testing.expectEqualStrings(
        "GENERIC BOOT machine=cortex-m33\n" ++
            "GENERIC END machine=cortex-m33 cpuid=410fd210 ticks=4 sum=10 status=PASS\n",
        run.itm,
    );
}

test "generic cortex-m85 firmware exercises MVE, LOB, and double-precision FPU" {
    const run = try runToPark(m85_elf, &catalog.cortex_m85);
    defer std.testing.allocator.free(run.itm);

    try std.testing.expectEqualSlices(u32, &.{
        0x474D_3835,
        0x410F_D230,
        0x0000_0000,
        0x0008_0008,
        5,
        165,
        0x401C_0000,
        1,
    }, &run.words);
    try std.testing.expectEqualStrings(
        "GENERIC BOOT machine=cortex-m85\n" ++
            "GENERIC END machine=cortex-m85 cpuid=410fd230 ticks=5 sum=165 status=PASS\n",
        run.itm,
    );
}

test "cortex-m85 firmware traps on cortex-m33 with UNDEFINSTR fault record" {
    const run = try runToPark(m85_elf, &catalog.cortex_m33);
    defer std.testing.allocator.free(run.itm);

    try std.testing.expectEqual(@as(u32, 0xFA01_7000), run.words[0]);
    try std.testing.expectEqual(@as(u32, 0x0001_0000), run.words[7]);
    try std.testing.expectEqualStrings(
        "GENERIC BOOT machine=cortex-m85\nGENERIC FAULT machine=cortex-m85\n",
        run.itm,
    );
}
