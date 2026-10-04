//! Tests for src/core/engine.zig.
const std = @import("std");
const ra8 = @import("ra8");
const clocks = ra8.periph.clocks;
const memmap = ra8.core.memmap;
const mod = ra8.core.engine;

const Engine = mod.Engine;
const Watch = mod.Watch;
const elf = ra8.core.elf;

fn copyImage() [0x3000]u8 {
    const page: usize = 0x1000;
    var file = [_]u8{0} ** (page * 3);
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
        .e_entry = 0x0200_0101,
        .e_phoff = @sizeOf(elf.Header),
        .e_shoff = 0,
        .e_flags = 0,
        .e_ehsize = @sizeOf(elf.Header),
        .e_phentsize = @sizeOf(elf.ProgramHeader),
        .e_phnum = 2,
        .e_shentsize = 0,
        .e_shnum = 0,
        .e_shstrndx = 0,
    };
    const vectors: *elf.ProgramHeader = @ptrCast(@alignCast(&file[@sizeOf(elf.Header)]));
    vectors.* = .{
        .p_type = elf.pt_load,
        .p_offset = page,
        .p_vaddr = 0x0200_0000,
        .p_paddr = 0x0200_0000,
        .p_filesz = 8,
        .p_memsz = 8,
        .p_flags = 4,
        .p_align = 4,
    };
    const code: *elf.ProgramHeader = @ptrCast(@alignCast(&file[@sizeOf(elf.Header) + @sizeOf(elf.ProgramHeader)]));
    code.* = .{
        .p_type = elf.pt_load,
        .p_offset = page * 2,
        .p_vaddr = 0x0200_0100,
        .p_paddr = 0x0200_0100,
        .p_filesz = 28,
        .p_memsz = 28,
        .p_flags = elf.pf_x | 4,
        .p_align = 4,
    };
    std.mem.writeInt(u32, file[page..][0..4], 0x2200_8000, .little);
    std.mem.writeInt(u32, file[page + 4 ..][0..4], 0x0200_0101, .little);
    const instructions = [_]u8{
        0x03, 0x48, // ldr r0, [pc, #12]
        0x04, 0x49, // ldr r1, [pc, #16]
        0x01, 0x60, // str r1, [r0]
        0x04, 0x4A, // ldr r2, [pc, #16]
        0x10, 0x47, // bx r2
        0x00, 0xBF, // nop
        0x00, 0xBF, // nop
        0x00, 0xBF, // nop
    };
    @memcpy(file[page * 2 ..][0..instructions.len], &instructions);
    std.mem.writeInt(u32, file[page * 2 + 16 ..][0..4], 0x2202_0000, .little);
    std.mem.writeInt(u32, file[page * 2 + 20 ..][0..4], 0xE7FE_222A, .little);
    std.mem.writeInt(u32, file[page * 2 + 24 ..][0..4], 0x2202_0001, .little);
    return file;
}
test "an engine opens, maps the board, and reads back what it wrote" {
    var engine = try Engine.open();
    defer engine.close();
    try engine.mapBoardRam();
    try engine.write(memmap.sram_base, &[_]u8{ 0x0D, 0xF0, 0xAD, 0x0B });
    try std.testing.expectEqual(@as(u32, 0x0BADF00D), try engine.readWord(memmap.sram_base));
    try engine.setRegister(.sp, memmap.sram_base + 0x100);
    try std.testing.expectEqual(memmap.sram_base + 0x100, try engine.register(.sp));
}

test "the M85 ITCM at zero is mapped for startup code copies" {
    var engine = try Engine.open();
    defer engine.close();
    try engine.mapBoardRam();
    try engine.writeWord(memmap.itcm_base, 0xC0DE_4260);
    try std.testing.expectEqual(@as(u32, 0xC0DE_4260), try engine.readWord(memmap.itcm_base));
}

test "a copied Thumb image runs from SRAM after its loaded reset vector" {
    var file = copyImage();
    const image = try elf.Image.init(&file);
    try std.testing.expectEqual(@as(u32, 0x0200_0000), image.vectorBase().?);

    var engine = try Engine.open();
    defer engine.close();
    try engine.mapBoardRam();
    try std.testing.expectEqual(@as(u32, 36), try engine.loadImage(image));
    try engine.resetFromVectorTable(image.vectorBase().?);

    const fault = try engine.run(try engine.register(.pc), 20, .{});
    try std.testing.expect(fault == null);
    try std.testing.expectEqual(@as(u32, 0xE7FE_222A), try engine.readWord(0x2202_0000));
    try std.testing.expectEqual(@as(u32, 42), try engine.register(.r2));
    try std.testing.expectEqual(@as(u32, 0x2202_0002), try engine.register(.pc));
}

test "a fault reports the address it reached for and the instruction that did it" {
    var engine = try Engine.open();
    defer engine.close();
    try engine.mapBoardRam();

    var watch = Watch{};
    try engine.attachWatch(&watch);

    // r0 = 0x90000000 (nothing is mapped there); str r1, [r0].
    const code = [_]u8{
        0x40, 0xF2, 0x00, 0x00, // movw r0, #0
        0xC9, 0xF2, 0x00, 0x00, // movt r0, #0x9000
        0x55, 0x21, //             movs r1, #0x55
        0x01, 0x60, //             str  r1, [r0]
    };
    try engine.write(memmap.sram_base, &code);
    try engine.setRegister(.sp, memmap.sram_base + 0x1000);

    const fault = (try engine.run(memmap.sram_base, 4, .{ .watch = &watch })) orelse return error.TestExpectedFault;
    const access = fault.access orelse return error.TestExpectedAccess;
    try std.testing.expectEqual(@as(u64, 0x9000_0000), access.address);
    try std.testing.expectEqual(@as(u8, 4), access.size);
    try std.testing.expect(access.kind == .write);
    try std.testing.expectEqualStrings("str r1, [r0]", (fault.instruction orelse return error.TestExpectedText).slice());
}

test "a chunked run charges the clocks and lets a CYCCNT wait finish" {
    var core = try Engine.open();
    defer core.close();
    try core.mapBoardRam();

    // What ra8_time_init arms before anything waits on the counter.
    try core.writeWord(memmap.scb.demcr, clocks.demcr_trcena);
    try core.writeWord(memmap.dwt.ctrl, clocks.dwt_ctrl_cyccntena);
    try core.writeWord(memmap.dwt.cyccnt, 0);
    try core.writeWord(memmap.syst.rvr, 99);
    try core.writeWord(memmap.syst.cvr, 99);
    try core.writeWord(memmap.syst.csr, clocks.csr_enable | clocks.csr_tickint);

    // b . : the shape of every wait loop, and what one looks like to the core.
    try core.write(memmap.sram_base, &[_]u8{ 0xFE, 0xE7 });
    try core.setRegister(.sp, memmap.sram_base + 0x1000);

    var timebase = clocks.Clocks{ .per_chunk = 64 };
    const fault = try core.run(memmap.sram_base, 256, .{ .timebase = &timebase });
    try std.testing.expect(fault == null);

    // Four chunks of 64: the cycle counter moved, so a CYCCNT wait completes.
    try std.testing.expectEqual(@as(u64, 256), timebase.cycles);
    try std.testing.expectEqual(@as(u32, 256), try core.readWord(memmap.dwt.cyccnt));
    // 256 instructions over a 100-tick period: two full periods and change.
    try std.testing.expectEqual(@as(u64, 2), timebase.ticks);
    try std.testing.expect(try core.readWord(memmap.scb.icsr) & clocks.icsr_pendstset != 0);
}

test "without a time base the run is one stretch and the clocks stand still" {
    var core = try Engine.open();
    defer core.close();
    try core.mapBoardRam();
    try core.writeWord(memmap.scb.demcr, clocks.demcr_trcena);
    try core.writeWord(memmap.dwt.ctrl, clocks.dwt_ctrl_cyccntena);
    try core.write(memmap.sram_base, &[_]u8{ 0xFE, 0xE7 });
    try core.setRegister(.sp, memmap.sram_base + 0x1000);

    try std.testing.expect(try core.run(memmap.sram_base, 256, .{}) == null);
    try std.testing.expectEqual(@as(u32, 0), try core.readWord(memmap.dwt.cyccnt));
}

test "a reset takes SP and PC from the vector table and leaves LR all ones" {
    var engine = try Engine.open();
    defer engine.close();
    try engine.mapBoardRam();
    const table = memmap.sram_base;
    try engine.write(table, &[_]u8{ 0x00, 0x10, 0x00, 0x22, 0x41, 0x02, 0x00, 0x22 });
    try engine.setRegister(.lr, 0);
    try engine.resetFromVectorTable(table);
    try std.testing.expectEqual(@as(u32, 0x2200_1000), try engine.register(.sp));
    try std.testing.expectEqual(@as(u32, 0x2200_0240), try engine.register(.pc));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), try engine.register(.lr));
}

test "a read past the bytes an image loads still lands in code MRAM" {
    var engine = try Engine.open();
    defer engine.close();
    try engine.mapBoardRam();
    try engine.write(memmap.mram_base + 0x8_0000, &[_]u8{ 0x00, 0x00, 0x18, 0x32 });
    try std.testing.expectEqual(@as(u32, 0x3218_0000), try engine.readWord(memmap.mram_base + 0x8_0000));
    try std.testing.expectEqual(@as(u32, 0), try engine.readWord(memmap.mram_base + 0x8_1000));
}
