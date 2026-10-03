//! Tests for src/core/board_ram.zig.
const std = @import("std");
const ra8 = @import("ra8");
const mod = ra8.core.board_ram;
const memmap = ra8.core.memmap;
const Engine = ra8.core.engine.Engine;

test "a store through the Non-secure SRAM view is there in the Secure one" {
    var core = try Engine.open();
    defer core.close();
    try core.mapBoardRam();

    // cpu1_pingpong_ipc's first boot marker, written by a permanent-NS
    // controller through the alias, and the address CPU0's probe reads.
    try core.writeWord(0x3210_0200, 0xC0DE_DEAD);
    try std.testing.expectEqual(@as(u32, 0xC0DE_DEAD), try core.readWord(0x2210_0200));
}

test "a store through the Secure SRAM view is there in the Non-secure one" {
    var core = try Engine.open();
    defer core.close();
    try core.mapBoardRam();

    try core.writeWord(memmap.sram_base + 0x40, 0xB055_A55A);
    try std.testing.expectEqual(@as(u32, 0xB055_A55A), try core.readWord(memmap.ns_sram_base + 0x40));
}

test "the SDRAM alias shares its bytes both ways too" {
    var core = try Engine.open();
    defer core.close();
    try core.mapBoardRam();

    try core.writeWord(memmap.sdram_base + 0x100, 0x1234_5678);
    try std.testing.expectEqual(@as(u32, 0x1234_5678), try core.readWord(memmap.ns_sdram_base + 0x100));

    try core.writeWord(memmap.ns_sdram_base + 0x200, 0x8765_4321);
    try std.testing.expectEqual(@as(u32, 0x8765_4321), try core.readWord(memmap.sdram_base + 0x200));
}

test "two views of one region are not two views of every region" {
    var core = try Engine.open();
    defer core.close();
    try core.mapBoardRam();

    // The SRAM pair and the SDRAM pair are separate memories, so a store in
    // one is not visible in the other at the same offset.
    try core.writeWord(memmap.sram_base + 0x80, 0xAAAA_AAAA);
    try std.testing.expectEqual(@as(u32, 0), try core.readWord(memmap.sdram_base + 0x80));
}

test "a region handed over by pointer comes up at reset state, not at the last engine's" {
    // The CPU model zeroes a region it allocates itself. A region handed over
    // by pointer is whatever the host had, and the host allocator recycles,
    // so without zeroing this engine inherits whatever the one above it
    // wrote. Both engines are opened here so the test is about the recycling
    // and not only about a single fresh allocation.
    {
        var first = try Engine.open();
        defer first.close();
        try first.mapBoardRam();
        try first.writeWord(memmap.sram_base + 0x80, 0xAAAA_AAAA);
        try first.writeWord(memmap.sdram_base + 0x2000, 0xAAAA_AAAA);
    }
    var core = try Engine.open();
    defer core.close();
    try core.mapBoardRam();

    try std.testing.expectEqual(@as(u32, 0), try core.readWord(memmap.sram_base));
    try std.testing.expectEqual(@as(u32, 0), try core.readWord(memmap.sram_base + 0x80));
    try std.testing.expectEqual(@as(u32, 0), try core.readWord(memmap.ns_sram_base + 0x80));
    try std.testing.expectEqual(@as(u32, 0), try core.readWord(memmap.sdram_base + 0x2000));
}

test "every aliased region is allocated once and released on close" {
    var core = try Engine.open();
    try core.mapBoardRam();
    for (core.ram.backing) |held| {
        try std.testing.expect(held != null);
    }
    core.close();
    for (core.ram.backing) |held| {
        try std.testing.expect(held == null);
    }
}

test "the code MRAM has a pointer backing for a direct core view" {
    var core = try Engine.open();
    try core.mapBoardRam();
    const flash = core.ram.region(memmap.mram_base).?;
    try std.testing.expectEqual(@as(usize, memmap.mram_end - memmap.mram_base), flash.len);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(flash.ptr) % mod.page);
    core.close();
    try std.testing.expect(core.ram.mram == null);
}

test "the pages behind an aliased region are aligned for the CPU model" {
    var core = try Engine.open();
    defer core.close();
    try core.mapBoardRam();
    for (core.ram.backing) |held| {
        try std.testing.expectEqual(@as(usize, 0), @intFromPtr(held.?.ptr) % mod.page);
    }
}

test "covers answers for the board's regions and nothing else" {
    try std.testing.expect(mod.covers(memmap.sram_base, 4));
    try std.testing.expect(mod.covers(memmap.ns_sram_base, 4));
    try std.testing.expect(mod.covers(memmap.ppb_base, 4));
    // The whole code MRAM is the board's, so a page an image never loads
    // still answers.
    try std.testing.expect(mod.covers(memmap.mram_base + 0x8_1000, 4));
    try std.testing.expect(!mod.covers(memmap.mram_end - 2, 4));
    // A span running off the end of a region is not covered by it.
    try std.testing.expect(!mod.covers(memmap.sram_end - 2, 4));
}

test "permission bits follow the region" {
    const all = mod.protOf(.{});
    const no_exec = mod.protOf(.{ .exec = false });
    try std.testing.expect(all != no_exec);
    try std.testing.expect(all > no_exec);
}

test "a second core mapped onto the first sees what the first wrote" {
    var cpu0 = try Engine.open();
    defer cpu0.close();
    try cpu0.mapBoardRam();
    var cpu1 = try Engine.open();
    defer cpu1.close();
    try cpu1.shareBoardRamWith(&cpu0);

    try cpu0.writeWord(memmap.sram_base + 0x100, 0xC0DE_DEAD);
    try std.testing.expectEqual(@as(u32, 0xC0DE_DEAD), try cpu1.readWord(memmap.sram_base + 0x100));
}

test "the cpu1 marker handshake crosses both the alias and the core" {
    var cpu0 = try Engine.open();
    defer cpu0.close();
    try cpu0.mapBoardRam();
    var cpu1 = try Engine.open();
    defer cpu1.close();
    try cpu1.shareBoardRamWith(&cpu0);

    // What cpu1_main.c actually does: CPU1 is a permanent-NS controller and
    // writes its boot markers through the Non-secure view, while CPU0 reads
    // the same bytes through the standard one.
    const marker = 0x0010_0200;
    try cpu1.writeWord(memmap.ns_sram_base + marker, 0xB055_A55A);
    try std.testing.expectEqual(@as(u32, 0xB055_A55A), try cpu0.readWord(memmap.sram_base + marker));
}

test "the sharing runs both directions across cores" {
    var cpu0 = try Engine.open();
    defer cpu0.close();
    try cpu0.mapBoardRam();
    var cpu1 = try Engine.open();
    defer cpu1.close();
    try cpu1.shareBoardRamWith(&cpu0);

    try cpu0.writeWord(memmap.sdram_base + 0x40, 0x1111_1111);
    try std.testing.expectEqual(@as(u32, 0x1111_1111), try cpu1.readWord(memmap.ns_sdram_base + 0x40));
    try cpu1.writeWord(memmap.ns_sdram_base + 0x44, 0x3333_3333);
    try std.testing.expectEqual(@as(u32, 0x3333_3333), try cpu0.readWord(memmap.sdram_base + 0x44));
}

test "a borrower owns its code but shares aliased RAM backing" {
    var cpu0 = try Engine.open();
    defer cpu0.close();
    try cpu0.mapBoardRam();
    var cpu1 = try Engine.open();
    defer cpu1.close();
    try cpu1.shareBoardRamWith(&cpu0);
    for (cpu1.ram.backing) |held| {
        try std.testing.expect(held == null);
    }
    try std.testing.expect(cpu1.ram.mram != null);
    try std.testing.expect(cpu0.ram.mapped());
    try std.testing.expect(!cpu1.ram.mapped());

    // Each core keeps its own loaded code even though both see shared SRAM.
    try cpu0.writeWord(memmap.mram_base + 0x100, 0xC0DE_DEAD);
    try std.testing.expectEqual(@as(u32, 0), try cpu1.readWord(memmap.mram_base + 0x100));
}

test "a core cannot be mapped onto a board nobody has mapped yet" {
    var cpu0 = try Engine.open();
    defer cpu0.close();
    var cpu1 = try Engine.open();
    defer cpu1.close();
    try std.testing.expectError(error.MapFailed, cpu1.shareBoardRamWith(&cpu0));
}
