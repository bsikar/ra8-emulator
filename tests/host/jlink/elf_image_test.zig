const std = @import("std");

const elf_image = @import("ra8").host.jlink.elf_image;

fn makeSyntheticArmElf(paddr: u32, payload: []const u8, out: []u8) []const u8 {
    @memset(out[0..84], 0);
    @memcpy(out[0..4], "\x7fELF");
    out[4] = 1; // ELFCLASS32
    out[5] = 1; // ELFDATA2LSB
    out[6] = 1; // EV_CURRENT
    std.mem.writeInt(u16, out[16..18], 2, .little); // ET_EXEC
    std.mem.writeInt(u16, out[18..20], 40, .little); // EM_ARM
    std.mem.writeInt(u32, out[20..24], 1, .little);
    std.mem.writeInt(u32, out[24..28], paddr | 1, .little);
    std.mem.writeInt(u32, out[28..32], 52, .little); // e_phoff
    std.mem.writeInt(u16, out[40..42], 52, .little);
    std.mem.writeInt(u16, out[42..44], 32, .little); // e_phentsize
    std.mem.writeInt(u16, out[44..46], 1, .little); // e_phnum

    // Single PT_LOAD header at offset 52..84, payload at 84..
    std.mem.writeInt(u32, out[52..56], 1, .little); // PT_LOAD
    std.mem.writeInt(u32, out[56..60], 84, .little); // p_offset
    std.mem.writeInt(u32, out[60..64], paddr, .little); // p_vaddr
    std.mem.writeInt(u32, out[64..68], paddr, .little); // p_paddr
    std.mem.writeInt(u32, out[68..72], @intCast(payload.len), .little); // p_filesz
    std.mem.writeInt(u32, out[72..76], @intCast(payload.len), .little); // p_memsz
    @memcpy(out[84..][0..payload.len], payload);
    return out[0 .. 84 + payload.len];
}

test "elf_image admits ARM32 flash images and rejects wrong-part or option-byte windows" {
    var raw_ra8: [256]u8 = undefined;
    const ra8_elf = makeSyntheticArmElf(0x0200_0000, "ra8e1-code", &raw_ra8);
    var segs: [elf_image.max_segments]elf_image.Segment = undefined;
    const summary = try elf_image.parse(ra8_elf, &segs);
    try std.testing.expectEqual(@as(usize, 1), summary.segments.len);
    try std.testing.expectEqual(@as(u32, 0x0200_0000), summary.segments[0].paddr);
    try std.testing.expectEqual(@as(usize, 10), summary.total_bytes);

    // Fits RA8E1 code flash (0x0200_0000..0x0210_0000), rejected by RA4T1 (0x0000_0000..0x0004_0000).
    try elf_image.checkWindow(summary.segments, 0x0200_0000, 0x0010_0000);
    try std.testing.expectError(error.AddressOutOfRange, elf_image.checkWindow(summary.segments, 0x0000_0000, 0x0004_0000));

    // Option-setting flash (0x0300_A100 on RA8E1) is rejected before touching hardware.
    var raw_opt: [256]u8 = undefined;
    const opt_elf = makeSyntheticArmElf(0x0300_A100, "ofs", &raw_opt);
    const opt_sum = try elf_image.parse(opt_elf, &segs);
    try std.testing.expectError(error.AddressOutOfRange, elf_image.checkWindow(opt_sum.segments, 0x0200_0000, 0x0010_0000));

    // Non-ELF and non-ARM ELF headers fail closed.
    try std.testing.expectError(error.NotElf, elf_image.parse("not-an-elf-binary----------------------------------------", &segs));
    raw_ra8[18] = 62; // EM_X86_64
    try std.testing.expectError(error.UnsupportedElfTarget, elf_image.parse(ra8_elf, &segs));
}
