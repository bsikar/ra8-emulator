//! Covers src/interfaces/cli/zig_memory.zig: CPU0 on its own store for a
//! single-core `--cpu zig` run (RA8EMU-580).
const std = @import("std");
const ra8 = @import("ra8");

const memmap = ra8.core.memmap;
const elf = ra8.core.elf;
const Cpu0 = ra8.board.zig_run.cpu0_memory.Cpu0;
const Options = ra8.core.cli.Options;

const page: usize = 0x1000;
const vectors: u32 = memmap.mram_base;
const stack: u32 = memmap.sram_base + 0x800;

/// One executable PT_LOAD segment in code MRAM, where a real image loads:
/// SP, reset, then B . at +8.
fn image() [page * 2]u8 {
    var file = [_]u8{0} ** (page * 2);
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
        .e_entry = vectors + 9,
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
    header.* = .{ .p_type = elf.pt_load, .p_offset = page, .p_vaddr = vectors, .p_paddr = vectors, .p_filesz = 0xC, .p_memsz = 0xC, .p_flags = 5, .p_align = 4 };
    std.mem.writeInt(u32, file[page..][0..4], stack, .little);
    std.mem.writeInt(u32, file[page + 4 ..][0..4], vectors + 9, .little);
    std.mem.writeInt(u16, file[page + 8 ..][0..2], 0xE7FE, .little);
    return file;
}

test "a single-core zig run loads CPU0 into its own store, not the engine" {
    var core = try ra8.core.engine.Engine.open();
    defer core.close();
    try core.mapBoardRam();
    var board = ra8.board.Board.init(std.testing.allocator);
    defer board.deinit();
    var file = image();
    var cpu0: Cpu0 = .{};
    defer cpu0.close();
    try cpu0.attach(&board, &core, try elf.Image.init(&file), .{ .path = "cpu0.elf", .cpu = .zig });
    const memory = cpu0.guest(core);
    try std.testing.expect(memory == .store);
    try std.testing.expectEqual(stack, try memory.readWord(vectors));
    try std.testing.expectEqual(ra8.periph.cpuid.cpu0, try memory.readWord(ra8.periph.cpuid.address));
    // The whole option window is mapped, its last page included, with room
    // left for an image page outside memmap.
    _ = try memory.readWord(0x02E1_79F0);
    try memory.map(0x02C9_F000, 0x1000);
    // The engine was never written: it holds none of the image.
    try std.testing.expectEqual(@as(u32, 0), core.readWord(vectors) catch 0);
}

test "a run with a second core, or on Unicorn, stays on the engine" {
    for ([_]Options{ .{ .path = "cpu0.elf", .cpu = .unicorn }, .{ .path = "cpu0.elf", .cpu = .zig, .cpu1_path = "cpu1.elf" }, .{ .path = "cpu0.elf", .cpu = .lockstep } }) |options| {
        var core = try ra8.core.engine.Engine.open();
        defer core.close();
        try core.mapBoardRam();
        var board = ra8.board.Board.init(std.testing.allocator);
        defer board.deinit();
        var file = image();
        var cpu0: Cpu0 = .{};
        defer cpu0.close();
        try cpu0.attach(&board, &core, try elf.Image.init(&file), options);
        try std.testing.expect(cpu0.guest(core) == .engine);
        try std.testing.expectEqual(@as(u32, 0), core.readWord(vectors) catch 0);
    }
}
