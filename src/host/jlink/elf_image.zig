//! Admission checks for 32-bit little-endian Arm (`EM_ARM`) firmware ELFs
//! before programming physical flash: header verification, bounded `PT_LOAD`
//! extraction, target flash-window containment (blocking wrong-part images and
//! option-byte regions), and SHA-256 hex fingerprinting.
const std = @import("std");

pub const max_elf_bytes: usize = 16 * 1024 * 1024;
pub const max_segments: usize = 16;

const et_exec: u16 = 2;
const em_arm: u16 = 40;
const pt_load: u32 = 1;

pub const Segment = struct {
    paddr: u32,
    bytes: []const u8,
};

pub const Summary = struct {
    entry: u32,
    total_bytes: usize,
    segments: []const Segment,
};

const Header = struct {
    entry: u32,
    phoff: usize,
    phentsize: usize,
    phnum: usize,
};

pub fn parse(elf: []const u8, out: *[max_segments]Segment) !Summary {
    const hdr = try parseHeader(elf);
    var count: usize = 0;
    var total_bytes: usize = 0;
    for (0..hdr.phnum) |index| {
        const maybe = try parseProgramHeader(elf, hdr.phoff + index * hdr.phentsize);
        const seg = maybe orelse continue;
        if (count == max_segments) return error.TooManySegments;
        out[count] = seg;
        count += 1;
        total_bytes += seg.bytes.len;
    }
    if (count == 0 or total_bytes == 0) return error.EmptyLoadImage;
    return .{ .entry = hdr.entry, .total_bytes = total_bytes, .segments = out[0..count] };
}

fn parseHeader(elf: []const u8) !Header {
    if (elf.len < 52 or elf.len > max_elf_bytes) return error.InvalidElf;
    if (!std.mem.eql(u8, elf[0..4], "\x7fELF")) return error.NotElf;
    if (elf[4] != 1 or elf[5] != 1 or elf[6] != 1) return error.UnsupportedElfTarget;
    if (readU16(elf, 16) != et_exec or readU16(elf, 18) != em_arm) return error.UnsupportedElfTarget;
    const phoff: usize = readU32(elf, 28);
    const phentsize: usize = readU16(elf, 42);
    const phnum: usize = readU16(elf, 44);
    if (phentsize < 32 or phnum == 0 or phnum > 64) return error.InvalidElf;
    const table_bytes = std.math.mul(usize, phentsize, phnum) catch return error.InvalidElf;
    const table_end = std.math.add(usize, phoff, table_bytes) catch return error.InvalidElf;
    if (table_end > elf.len) return error.InvalidElf;
    return .{ .entry = readU32(elf, 24), .phoff = phoff, .phentsize = phentsize, .phnum = phnum };
}

fn parseProgramHeader(elf: []const u8, base: usize) !?Segment {
    if (readU32(elf, base) != pt_load) return null;
    const filesz: usize = readU32(elf, base + 16);
    const memsz: usize = readU32(elf, base + 20);
    if (filesz > memsz) return error.InvalidElf;
    if (filesz == 0) return null;
    const offset: usize = readU32(elf, base + 4);
    const seg_end = std.math.add(usize, offset, filesz) catch return error.InvalidElf;
    if (seg_end > elf.len) return error.InvalidElf;
    const paddr = readU32(elf, base + 12);
    _ = std.math.add(u32, paddr, @intCast(filesz)) catch return error.AddressOutOfRange;
    return .{ .paddr = paddr, .bytes = elf[offset..seg_end] };
}

pub fn checkWindow(segments: []const Segment, flash_base: u32, flash_size: u32) !void {
    if (flash_size == 0) return error.InvalidFlashWindow;
    const window_end = std.math.add(u32, flash_base, flash_size) catch return error.InvalidFlashWindow;
    for (segments) |seg| {
        const seg_end = std.math.add(u32, seg.paddr, @intCast(seg.bytes.len)) catch return error.AddressOutOfRange;
        if (seg.paddr < flash_base or seg_end > window_end) return error.AddressOutOfRange;
    }
}

pub fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn readU16(bytes: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, bytes[at..][0..2], .little);
}

fn readU32(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
