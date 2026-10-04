//! Tests for src/core/second_zig.zig: CPU1 on the Zig core (RA8EMU-234).
const std = @import("std");
const ra8 = @import("ra8");
const second_core = ra8.core.second_core;
const SecondZig = second_core.zig.SecondZig;
const Engine = ra8.core.engine.Engine;
const memmap = ra8.core.memmap;
const Board = ra8.board.Board;

const vectors: u32 = memmap.sram_base + 0x1000;
const code: u32 = vectors + 0x200;
const stack: u32 = vectors + 0x800;
const usage_handler: u32 = vectors + 0x400;
const hard_handler: u32 = vectors + 0x440;
const usgfaultena: u32 = 1 << 18;

/// CPU0's engine with board RAM, and CPU1's engine sharing it, the way
/// `Second.open` sets them up.
fn pair(cpu1: *second_core.Second) !Engine {
    var cpu0 = try Engine.open();
    errdefer cpu0.close();
    try cpu0.mapBoardRam();
    cpu1.* = .{ .core = try Engine.open(), .vector_base = vectors };
    errdefer cpu1.close();
    try cpu1.core.shareBoardRamWith(&cpu0);
    try cpu1.core.writeWord(vectors, stack);
    try cpu1.core.writeWord(vectors + 4, code | 1);
    try cpu1.core.writeWord(vectors + 3 * 4, hard_handler | 1);
    try cpu1.core.writeWord(vectors + 6 * 4, usage_handler | 1);
    return cpu0;
}

fn halves(core: Engine, at: u32, words: []const u16) !void {
    for (words, 0..) |half, i| {
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &bytes, half, .little);
        try core.write(at + @as(u32, @intCast(2 * i)), &bytes);
    }
}

test "CPU1's Zig core resets from CPU1's vector table and runs its turn" {
    var cpu1: second_core.Second = undefined;
    var cpu0 = try pair(&cpu1);
    defer cpu0.close();
    defer cpu1.close();
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    // MOVS r0, #5; ADDS r0, #1; B .
    try halves(cpu1.core, code, &.{ 0x2005, 0x3001, 0xE7FE });

    var core: SecondZig = undefined;
    try core.open(&cpu1, &board.bus);
    try std.testing.expectEqual(stack, core.cpu.regs.sp());
    try std.testing.expectEqual(ra8.core.cpu.cpu.Stop.count, core.turn(2));
    try std.testing.expectEqual(@as(u32, 6), core.cpu.regs.get(0));
    try std.testing.expectEqual(@as(u64, 2), core.cpu.retired);
}

test "CPU1's Zig core is an M33 on the CPU1 side of the board" {
    var cpu1: second_core.Second = undefined;
    var cpu0 = try pair(&cpu1);
    defer cpu0.close();
    defer cpu1.close();
    var board = Board.init(std.testing.allocator);
    defer board.deinit();

    var core: SecondZig = undefined;
    try core.open(&cpu1, &board.bus);
    try std.testing.expectEqual(ra8.core.part.cpu1_profile, core.cpu.profile);
    try std.testing.expectEqual(ra8.periph.registry.Issuer.cpu1, core.board.issuer);
}

test "an MVE op on CPU1's Zig core takes UsageFault, not a step" {
    var cpu1: second_core.Second = undefined;
    var cpu0 = try pair(&cpu1);
    defer cpu0.close();
    defer cpu1.close();
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    // VADD.I32 q0, q1, q2, then B . in each handler.
    try halves(cpu1.core, code, &.{ 0xEF22, 0x0844 });
    try halves(cpu1.core, usage_handler, &.{0xE7FE});
    try halves(cpu1.core, hard_handler, &.{0xE7FE});

    var core: SecondZig = undefined;
    try core.open(&cpu1, &board.bus);
    try core.cpu.bus.write(memmap.scb.shcsr, std.mem.asBytes(&usgfaultena));
    try std.testing.expectEqual(ra8.core.cpu.cpu.Stop.count, core.turn(1));
    try std.testing.expectEqual(usage_handler, core.cpu.regs.pc);
    try std.testing.expectEqual(code, try cpu1.core.readWord(core.cpu.regs.sp() + 24));
}

test "CPU1's Zig core polls through its own quiet source (RA8EMU-440)" {
    var cpu1: second_core.Second = undefined;
    var cpu0 = try pair(&cpu1);
    defer cpu0.close();
    defer cpu1.close();
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    // B . with nothing pending: the poll settles and stays settled.
    try halves(cpu1.core, code, &.{0xE7FE});

    var core: SecondZig = undefined;
    try core.open(&cpu1, &board.bus);
    try std.testing.expectEqual(&core.quiet, core.cpu.quiet.?);
    try std.testing.expectEqual(ra8.core.cpu.cpu.Stop.count, core.turn(4));
    try std.testing.expect(core.quiet.settled);
    // A RAM store leaves the answer standing; a peripheral store stirs it.
    try core.cpu.bus.write(code + 0x100, &.{ 1, 2, 3, 4 });
    try std.testing.expect(core.quiet.settled);
    core.cpu.bus.write(0x4000_0000, &.{ 0, 0, 0, 0 }) catch {};
    try std.testing.expect(!core.quiet.settled);
}

test "CPU1's Zig core stores through its Guest into CPU1's memory (RA8EMU-535)" {
    var cpu1: second_core.Second = undefined;
    var cpu0 = try pair(&cpu1);
    defer cpu0.close();
    defer cpu1.close();
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var core: SecondZig = undefined;
    try core.open(&cpu1, &board.bus);
    try std.testing.expect(core.memory == .engine);
    try core.cpu.bus.write(code + 0x40, &.{ 0xEF, 0xBE, 0xAD, 0xDE });
    var bytes: [4]u8 = undefined;
    try cpu1.core.read(code + 0x40, &bytes);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), std.mem.readInt(u32, &bytes, .little));
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), try core.memory.readWord(code + 0x40));
}

const store_page: usize = 0x1000;
const store_vectors: u32 = memmap.sram_base + 0x1000;
const store_stack: u32 = store_vectors + 0x800;

/// One executable PT_LOAD segment at `store_vectors`: a vector pair, then
/// MOVS r0, #5; ADDS r0, #1; B . at +0x200.
fn cpu1Image() [store_page * 2]u8 {
    var file = [_]u8{0} ** (store_page * 2);
    const elf = ra8.core.elf;
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
        .e_entry = store_vectors + 0x201,
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
    header.* = .{ .p_type = elf.pt_load, .p_offset = store_page, .p_vaddr = store_vectors, .p_paddr = store_vectors, .p_filesz = 0x208, .p_memsz = 0x208, .p_flags = 5, .p_align = 4 };
    std.mem.writeInt(u32, file[store_page..][0..4], store_stack, .little);
    std.mem.writeInt(u32, file[store_page + 4 ..][0..4], store_vectors + 0x201, .little);
    for ([_]u16{ 0x2005, 0x3001, 0xE7FE }, 0..) |half, i| {
        std.mem.writeInt(u16, file[store_page + 0x200 + 2 * i ..][0..2], half, .little);
    }
    return file;
}

test "CPU1's Zig core resets and runs over a store with no engine open" {
    var file = cpu1Image();
    const image = try ra8.core.elf.Image.init(&file);
    var store = try ra8.core.cpu.memory.store.Store.init(null);
    defer store.deinit();
    const memory: ra8.core.cpu.memory.guest.Guest = .{ .store = &store };
    const seeded = try second_core.seedImage(memory, image);
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var partitions = ra8.periph.sau.Sau.init();
    var regions = ra8.periph.mpu.Mpu.init();
    var clears = ra8.periph.fault_status.clear.Clears.init();
    var core: SecondZig = undefined;
    try core.openOn(memory, .{ .partitions = &partitions, .regions = &regions, .clears = &clears, .vector_base = seeded.vector_base }, &board.bus);
    try std.testing.expectEqual(store_stack, core.cpu.regs.sp());
    try std.testing.expectEqual(ra8.core.cpu.cpu.Stop.count, core.turn(2));
    try std.testing.expectEqual(@as(u32, 6), core.cpu.regs.get(0));
}
