//! The sweep for encodings the architecture leaves undefined.
const std = @import("std");
const ra8 = @import("ra8");
const undefined_ops = ra8.core.undefined_ops;
const elf = ra8.core.elf;

/// The instruction that cost four sessions: orrs.w r3, r2, pc, lsl #2.
const orrs_pc = [2]u16{ 0xEA52, 0x038F };

/// The same shape the compiler should have emitted: orr.w r3, r3, r2, lsr #30.
const orr_clean = [2]u16{ 0xEA43, 0x7392 };

test "the program counter as a shifted operand is undefined" {
    try std.testing.expect(undefined_ops.shiftedPc(orrs_pc[0], orrs_pc[1]));
}

test "the same instruction on a real register is not" {
    try std.testing.expect(!undefined_ops.shiftedPc(orr_clean[0], orr_clean[1]));
}

test "a wider shift of the program counter is undefined too" {
    // orrs.w r3, r2, pc, lsl #3, the sibling site in the same image.
    try std.testing.expect(undefined_ops.shiftedPc(0xEA52, 0x03CF));
}

test "a branch that happens to end in fifteen is not this class" {
    // Bit 15 of the second halfword is set on a branch, never on this class.
    try std.testing.expect(!undefined_ops.shiftedPc(0xF000, 0xB80F));
}

test "a coprocessor encoding is not this class" {
    try std.testing.expect(!undefined_ops.shiftedPc(0xED2F, 0x0B0F));
}

test "a sixteen bit halfword is not the start of a wide instruction" {
    try std.testing.expect(!undefined_ops.isWide(0x4610));
    try std.testing.expect(undefined_ops.isWide(0xEA52));
}

test "the list stops but the count does not" {
    var found = undefined_ops.Found{};
    for (0..undefined_ops.limits.listed + 3) |step| {
        const site = undefined_ops.Site{ .address = @intCast(step), .encoding = 0 };
        // add is private, so go through a sweep-shaped path: write directly.
        if (found.count < undefined_ops.limits.listed) found.sites[found.count] = site;
        found.count += 1;
    }
    try std.testing.expectEqual(undefined_ops.limits.listed + 3, found.count);
    try std.testing.expectEqual(undefined_ops.limits.listed, found.listed().len);
}

/// An ELF32 ARM image carrying one executable segment of the given bytes.
fn imageWith(buffer: []u8, code: []const u8, vaddr: u32) elf.Image {
    @memset(buffer, 0);
    const head = std.mem.bytesAsValue(elf.Header, buffer[0..@sizeOf(elf.Header)]);
    @memcpy(&head.magic, "\x7fELF");
    head.class = 1;
    head.data = 1;
    head.e_machine = elf.em_arm;
    head.e_phoff = @sizeOf(elf.Header);
    head.e_phentsize = @sizeOf(elf.ProgramHeader);
    head.e_phnum = 1;
    const at = @as(usize, head.e_phoff);
    const ph = std.mem.bytesAsValue(elf.ProgramHeader, buffer[at..][0..@sizeOf(elf.ProgramHeader)]);
    ph.p_type = elf.pt_load;
    ph.p_flags = elf.pf_x;
    ph.p_offset = @intCast(at + @sizeOf(elf.ProgramHeader));
    ph.p_vaddr = vaddr;
    ph.p_paddr = vaddr;
    ph.p_filesz = @intCast(code.len);
    ph.p_memsz = @intCast(code.len);
    @memcpy(buffer[ph.p_offset..][0..code.len], code);
    return elf.Image.init(buffer) catch unreachable;
}

test "a sweep names the site at its own address" {
    // mov r0, r2 ; orrs.w r3, r2, pc, lsl #2 ; mov r1, r3
    const code = [_]u8{ 0x10, 0x46, 0x52, 0xEA, 0x8F, 0x03, 0x19, 0x46 };
    var buffer: [256]u8 = undefined;
    const found = undefined_ops.sweep(imageWith(&buffer, &code, 0x02007000));
    try std.testing.expectEqual(@as(usize, 1), found.count);
    try std.testing.expectEqual(@as(u32, 0x02007002), found.listed()[0].address);
    try std.testing.expectEqual(@as(u32, 0xEA52038F), found.listed()[0].encoding);
}

test "a clean image sweeps to nothing" {
    const code = [_]u8{ 0x10, 0x46, 0x43, 0xEA, 0x92, 0x73, 0x19, 0x46 };
    var buffer: [256]u8 = undefined;
    const found = undefined_ops.sweep(imageWith(&buffer, &code, 0x02007000));
    try std.testing.expectEqual(@as(usize, 0), found.count);
}

test "a non executable segment is not swept" {
    const code = [_]u8{ 0x52, 0xEA, 0x8F, 0x03 };
    var buffer: [256]u8 = undefined;
    var image = imageWith(&buffer, &code, 0x02007000);
    const at = @as(usize, image.header().e_phoff);
    const ph = std.mem.bytesAsValue(elf.ProgramHeader, buffer[at..][0..@sizeOf(elf.ProgramHeader)]);
    ph.p_flags = 4;
    image = elf.Image.init(&buffer) catch unreachable;
    try std.testing.expectEqual(@as(usize, 0), undefined_ops.sweep(image).count);
}

test "nothing found prints nothing" {
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    try undefined_ops.print(out.writer(), .{});
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "a site prints its address and its encoding" {
    var found = undefined_ops.Found{};
    found.sites[0] = .{ .address = 0x02007498, .encoding = 0xEA52038F };
    found.count = 1;
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    try undefined_ops.print(out.writer(), found);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "1 site(s)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "0x02007498 EA52038F") != null);
}
