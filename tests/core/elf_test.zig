//! Tests for src/core/elf.zig.
const std = @import("std");
const ra8 = @import("ra8");
const memmap = ra8.core.memmap;
const mod = ra8.core.elf;

const Error = mod.Error;
const Header = mod.Header;
const Image = mod.Image;
const ProgramHeader = mod.ProgramHeader;
const Segment = mod.Segment;
const em_arm = mod.em_arm;
const pf_x = mod.pf_x;
const pt_load = mod.pt_load;
test "rejects a file that is not a little-endian 32-bit ARM ELF" {
    var buffer = [_]u8{0} ** @sizeOf(Header);
    try std.testing.expectError(Error.Truncated, Image.init(buffer[0..8]));
    try std.testing.expectError(Error.NotElf32, Image.init(&buffer));
    @memcpy(buffer[0..4], "\x7fELF");
    buffer[4] = 2;
    try std.testing.expectError(Error.NotElf32, Image.init(&buffer));
    buffer[4] = 1;
    buffer[5] = 2;
    try std.testing.expectError(Error.NotLittleEndian, Image.init(&buffer));
    buffer[5] = 1;
    try std.testing.expectError(Error.NotArm, Image.init(&buffer));
}

test "finds a non-executable vector segment before the code it points into" {
    const page = 0x1000;
    var file = [_]u8{0} ** (page * 3);
    const head: *Header = @ptrCast(@alignCast(&file[0]));
    head.* = .{
        .magic = .{ 0x7f, 'E', 'L', 'F' },
        .class = 1,
        .data = 1,
        .version = 1,
        .osabi = 0,
        .abiversion = 0,
        .pad = .{0} ** 7,
        .e_type = 2,
        .e_machine = em_arm,
        .e_version = 1,
        .e_entry = 0x0200_0489,
        .e_phoff = @sizeOf(Header),
        .e_shoff = 0,
        .e_flags = 0,
        .e_ehsize = @sizeOf(Header),
        .e_phentsize = @sizeOf(ProgramHeader),
        .e_phnum = 2,
        .e_shentsize = 0,
        .e_shnum = 0,
        .e_shstrndx = 0,
    };
    const ph: *ProgramHeader = @ptrCast(@alignCast(&file[@sizeOf(Header)]));
    ph.* = .{
        .p_type = pt_load,
        .p_offset = page,
        .p_vaddr = 0x0200_0000,
        .p_paddr = 0x0200_0000,
        .p_filesz = 16,
        .p_memsz = 32,
        .p_flags = 4,
        .p_align = 4,
    };
    const code_ph: *ProgramHeader = @ptrCast(@alignCast(&file[@sizeOf(Header) + @sizeOf(ProgramHeader)]));
    code_ph.* = .{
        .p_type = pt_load,
        .p_offset = page * 2,
        .p_vaddr = 0x0200_0488,
        .p_paddr = 0x0200_0488,
        .p_filesz = 16,
        .p_memsz = 32,
        .p_flags = pf_x | 4,
        .p_align = 4,
    };
    std.mem.writeInt(u32, file[page..][0..4], 0x2201_0000, .little);
    std.mem.writeInt(u32, file[page + 4 ..][0..4], 0x0200_0489, .little);
    const image = try Image.init(&file);
    const segment = image.loadSegment(0).?;
    try std.testing.expectEqual(@as(u32, 0x0200_0000), segment.paddr);
    try std.testing.expectEqual(@as(usize, 16), segment.bytes.len);
    try std.testing.expect(!segment.executable());
    try std.testing.expectEqual(@as(u32, 0x0200_0000), image.vectorBase().?);
}

test "a segment whose file bytes run past the end is refused, not trusted" {
    var file = [_]u8{0} ** (@sizeOf(Header) + @sizeOf(ProgramHeader));
    const head: *Header = @ptrCast(@alignCast(&file[0]));
    head.magic = .{ 0x7f, 'E', 'L', 'F' };
    head.class = 1;
    head.data = 1;
    head.e_machine = em_arm;
    head.e_phoff = @sizeOf(Header);
    head.e_phentsize = @sizeOf(ProgramHeader);
    head.e_phnum = 1;
    const ph: *ProgramHeader = @ptrCast(@alignCast(&file[@sizeOf(Header)]));
    ph.p_type = pt_load;
    ph.p_offset = 0;
    ph.p_filesz = 0xFFFF;
    const image = try Image.init(&file);
    try std.testing.expectEqual(@as(?Segment, null), image.loadSegment(0));
    try std.testing.expectEqual(@as(?u32, null), image.vectorBase());
    _ = memmap.ram;
}
