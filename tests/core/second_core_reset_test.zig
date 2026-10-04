//! Tests for src/core/second_core.zig: a SYSRESETREQ from CPU1 (RA8EMU-59),
//! and seeding CPU1 with no engine open (RA8EMU-571).
const std = @import("std");
const ra8 = @import("ra8");
const mod = ra8.core.second_core;
const memmap = ra8.core.memmap;
const Engine = ra8.core.engine.Engine;
const Board = ra8.board.Board;
const scb = ra8.periph.scb;
const cpu_ctrl = ra8.periph.cpu_ctrl;
const elf = ra8.core.elf;
const Store = ra8.core.cpu.memory.store.Store;
const Guest = ra8.core.cpu.memory.guest.Guest;

/// CPU1 beside CPU0 on shared RAM, built into storage the caller holds.
fn pair(cpu1: *mod.Second) !Engine {
    var cpu0 = try Engine.open();
    errdefer cpu0.close();
    try cpu0.mapBoardRam();
    cpu1.* = .{ .core = try Engine.open() };
    errdefer cpu1.close();
    try cpu1.core.shareBoardRamWith(&cpu0);
    return cpu0;
}

test "a reset CPU1 asks for latches SWRF and reboots the part, as CPU0's does" {
    var cpu1: mod.Second = undefined;
    var cpu0 = try pair(&cpu1);
    defer cpu0.close();
    defer cpu1.close();
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var pending: ra8.core.reboot.Reboot = .{};
    board.reboot = &pending;
    cpu1.control = scb.Scb.init();
    try cpu1.control.prime(cpu1.core);
    cpu1.takeResetRequest();
    try std.testing.expect(!pending.requested);

    cpu1.state.board = &board;
    const keyed: u32 = scb.key.write << scb.key.shift;
    try cpu1.core.writeWord(memmap.scb.aircr, keyed | scb.field.sysresetreq);
    cpu1.takeResetRequest();
    try std.testing.expect(pending.requested);
    try std.testing.expect(board.causes.rstsr1 & ra8.periph.reset.cause.swrf != 0);
    try std.testing.expectEqual(@as(u32, 1), board.causes.requests);
}

test "a reset the board performs holds CPU1, which then retires nothing" {
    var cpu1: mod.Second = undefined;
    var cpu0 = try pair(&cpu1);
    defer cpu0.close();
    defer cpu1.close();
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var pending: ra8.core.reboot.Reboot = .{};
    board.reboot = &pending;
    cpu1.state.board = &board;
    try std.testing.expect(!cpu1.heldInReset());

    pending.performed = 1;
    try std.testing.expect(cpu1.heldInReset());
    cpu1.step(100);
    try std.testing.expectEqual(@as(usize, 0), cpu1.state.ran);
    try std.testing.expectEqual(@as(u32, 0), cpu1.state.turns);
    try std.testing.expect(cpu1.heldInReset());
}

test "a core with no board is never held" {
    var cpu1: mod.Second = undefined;
    var cpu0 = try pair(&cpu1);
    defer cpu0.close();
    defer cpu1.close();
    try std.testing.expect(!cpu1.heldInReset());
}

test "a fresh release after a reset brings CPU1 up out of CPU1INITVTOR" {
    var cpu1: mod.Second = undefined;
    var cpu0 = try pair(&cpu1);
    defer cpu0.close();
    defer cpu1.close();
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var pending: ra8.core.reboot.Reboot = .{};
    board.reboot = &pending;
    cpu1.state.board = &board;
    const table: u32 = memmap.sram_base + 0x400;
    try cpu0.writeWord(table, memmap.sram_base + 0x8000);
    try cpu0.writeWord(table + 4, memmap.sram_base + 0x101);

    board.requestReset(.software);
    pending.performed = 1;
    try std.testing.expect(cpu1.heldInReset());
    const page = &board.second_core;
    page.write(cpu_ctrl.win_base + cpu_ctrl.regs.initvtor, 4, table);
    page.write(cpu_ctrl.win_base + cpu_ctrl.regs.actcsr, 2, cpu_ctrl.key.value | cpu_ctrl.bits.actreq);
    try std.testing.expect(!cpu1.heldInReset());
    try std.testing.expectEqual(@as(u32, 1), cpu1.state.restarts);
    try std.testing.expectEqual(table, cpu1.state.vector_base);
    try std.testing.expectEqual(memmap.sram_base + 0x100, cpu1.state.pc & ~@as(u32, 1));
    try std.testing.expectEqual(table, try cpu1.core.readWord(memmap.scb.vtor));
}

test "a reset clears the release, so CPU1 stays held until CPU0 asks again" {
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    const page = &board.second_core;
    page.write(cpu_ctrl.win_base + cpu_ctrl.regs.actcsr, 2, cpu_ctrl.key.value | cpu_ctrl.bits.actreq);
    board.requestReset(.software);
    try std.testing.expect(!page.running());
}

const seed_page: usize = 0x1000;

/// One executable PT_LOAD segment at MRAM holding a vector pair whose
/// reset vector points back inside it, so vectorBase accepts it.
fn vectorImage() [seed_page * 2]u8 {
    var file = [_]u8{0} ** (seed_page * 2);
    const head: *elf.Header = @ptrCast(@alignCast(&file[0]));
    head.* = .{
        .magic = .{ 0x7f, 'E', 'L', 'F' },
        .class = 1,
        .data = 1,
        .version = 1,
        .osabi = 0,
        .abiversion = 0,
        .pad = .{0} ** 7,
        .e_type = 2,
        .e_machine = elf.em_arm,
        .e_version = 1,
        .e_entry = memmap.mram_base + 0x5,
        .e_phoff = @sizeOf(elf.Header),
        .e_shoff = 0,
        .e_flags = 0,
        .e_ehsize = @sizeOf(elf.Header),
        .e_phentsize = @sizeOf(elf.ProgramHeader),
        .e_phnum = 1,
        .e_shentsize = 0,
        .e_shnum = 0,
        .e_shstrndx = 0,
    };
    const header: *elf.ProgramHeader = @ptrCast(@alignCast(&file[@sizeOf(elf.Header)]));
    header.* = .{ .p_type = elf.pt_load, .p_offset = seed_page, .p_vaddr = memmap.mram_base, .p_paddr = memmap.mram_base, .p_filesz = 8, .p_memsz = 8, .p_flags = 5, .p_align = 4 };
    std.mem.writeInt(u32, file[seed_page..][0..4], memmap.sram_base + 0x8000, .little);
    std.mem.writeInt(u32, file[seed_page + 4 ..][0..4], memmap.mram_base + 0x5, .little);
    return file;
}

test "CPU1's image and VTOR are seeded into a store with no engine open" {
    var file = vectorImage();
    const image = try elf.Image.init(&file);
    var store = try Store.init(null);
    defer store.deinit();
    const memory: Guest = .{ .store = &store };
    const seeded = try mod.seedImage(memory, image);
    try std.testing.expectEqual(@as(u32, 8), seeded.written);
    try std.testing.expectEqual(memmap.mram_base, seeded.vector_base);
    try std.testing.expectEqual(memmap.mram_base, try memory.readWord(memmap.scb.vtor));
    try std.testing.expectEqual(memmap.sram_base + 0x8000, try memory.readWord(memmap.mram_base));
    try std.testing.expectEqual(memmap.mram_base + 0x5, try memory.readWord(memmap.mram_base + 4));
}

test {
    _ = @import("second_state_test.zig");
}
