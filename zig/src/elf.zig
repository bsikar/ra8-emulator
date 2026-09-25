//! ELF32 image services, ported from src/engine/emu_elf.c.
//!
//! The C version walked the file with named byte offsets because it parsed
//! straight out of a byte buffer. Zig reads the same layout as packed structs,
//! so the offsets are the struct fields and the bounds checks are slices.
const std = @import("std");
const memmap = @import("memmap.zig");

pub const Error = error{
    NotElf32,
    NotLittleEndian,
    NotArm,
    Truncated,
    NoLoadableSegment,
};

pub const em_arm: u16 = 40;
pub const pt_load: u32 = 1;
pub const pf_x: u32 = 1;

pub const Header = extern struct {
    magic: [4]u8,
    class: u8,
    data: u8,
    version: u8,
    osabi: u8,
    abiversion: u8,
    pad: [7]u8,
    e_type: u16,
    e_machine: u16,
    e_version: u32,
    e_entry: u32,
    e_phoff: u32,
    e_shoff: u32,
    e_flags: u32,
    e_ehsize: u16,
    e_phentsize: u16,
    e_phnum: u16,
    e_shentsize: u16,
    e_shnum: u16,
    e_shstrndx: u16,
};

pub const ProgramHeader = extern struct {
    p_type: u32,
    p_offset: u32,
    p_vaddr: u32,
    p_paddr: u32,
    p_filesz: u32,
    p_memsz: u32,
    p_flags: u32,
    p_align: u32,
};

pub const Segment = struct {
    vaddr: u32,
    paddr: u32,
    flags: u32,
    bytes: []const u8,
    memsz: u32,

    pub fn executable(self: Segment) bool {
        return (self.flags & pf_x) != 0;
    }
};

/// An immutable view of a firmware image, the Zig shape of emu_elf_source_t.
pub const Image = struct {
    bytes: []const u8,

    pub fn init(bytes: []const u8) Error!Image {
        if (bytes.len < @sizeOf(Header)) return Error.Truncated;
        const head = std.mem.bytesAsValue(Header, bytes[0..@sizeOf(Header)]);
        if (!std.mem.eql(u8, &head.magic, "\x7fELF")) return Error.NotElf32;
        if (head.class != 1) return Error.NotElf32;
        if (head.data != 1) return Error.NotLittleEndian;
        if (head.e_machine != em_arm) return Error.NotArm;
        return .{ .bytes = bytes };
    }

    pub fn header(self: Image) *align(1) const Header {
        return std.mem.bytesAsValue(Header, self.bytes[0..@sizeOf(Header)]);
    }

    pub fn segmentCount(self: Image) u16 {
        return self.header().e_phnum;
    }

    /// One bounds-checked PT_LOAD segment, or null when the index is not one.
    pub fn loadSegment(self: Image, index: u16) ?Segment {
        const head = self.header();
        if (index >= head.e_phnum) return null;
        if (head.e_phentsize < @sizeOf(ProgramHeader)) return null;
        const start = @as(usize, head.e_phoff) + @as(usize, index) * @as(usize, head.e_phentsize);
        if (start + @sizeOf(ProgramHeader) > self.bytes.len) return null;
        const ph: *align(1) const ProgramHeader = std.mem.bytesAsValue(ProgramHeader, self.bytes[start..][0..@sizeOf(ProgramHeader)]);
        if (ph.p_type != pt_load or ph.p_filesz == 0) return null;
        const from = @as(usize, ph.p_offset);
        const to = from + @as(usize, ph.p_filesz);
        if (to > self.bytes.len) return null;
        return .{
            .vaddr = ph.p_vaddr,
            .paddr = ph.p_paddr,
            .flags = ph.p_flags,
            .bytes = self.bytes[from..to],
            .memsz = ph.p_memsz,
        };
    }

    /// The vector table sits at the lowest executable segment's VMA, exactly
    /// as elf_vector_base() derived it.
    pub fn vectorBase(self: Image) ?u32 {
        var lowest: ?u32 = null;
        var index: u16 = 0;
        while (index < self.segmentCount()) : (index += 1) {
            const segment = self.loadSegment(index) orelse continue;
            if (!segment.executable()) continue;
            if (lowest == null or segment.vaddr < lowest.?) lowest = segment.vaddr;
        }
        return lowest;
    }
};

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

test "walks one PT_LOAD segment and finds the vector base" {
    const page = 0x1000;
    var file = [_]u8{0} ** (page * 2);
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
        .e_entry = 0x0200_0001,
        .e_phoff = @sizeOf(Header),
        .e_shoff = 0,
        .e_flags = 0,
        .e_ehsize = @sizeOf(Header),
        .e_phentsize = @sizeOf(ProgramHeader),
        .e_phnum = 1,
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
        .p_flags = pf_x | 4,
        .p_align = 4,
    };
    const image = try Image.init(&file);
    const segment = image.loadSegment(0).?;
    try std.testing.expectEqual(@as(u32, 0x0200_0000), segment.paddr);
    try std.testing.expectEqual(@as(usize, 16), segment.bytes.len);
    try std.testing.expect(segment.executable());
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
