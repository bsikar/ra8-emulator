//! Covers src/session/history/state_memory.zig: two memory sections are
//! compared as held, except where either image loaded unmutated read-only or
//! load-copy bytes. Legitimate rebuilt RO/load-copy changes (including extra
//! RO pages and Non-Secure aliases) match, while post-load guest writes to
//! RO/code/load-copy bytes or zero-wiped RO pages diverge at the exact byte.
const std = @import("std");
const ra8 = @import("ra8");

const memory = ra8.session.history_state_memory;
const memmap = ra8.chip.core.memmap;
const elf = ra8.board.image.elf;

const gpa = std.testing.allocator;

const rom_base: u32 = 0x1000;
const flash_copy: u32 = 0x1100;
const ram_base: u32 = 0x2000_0000;

/// A one-region section: the page at offset 0 holds `bytes`, the rest of
/// the 4 KiB region is left out.
fn section(out: *std.ArrayList(u8), base: u32, bytes: []const u8) !void {
    for ([_]u32{ 1, base, memory.page, 1, 0 }) |word| try out.appendSlice(gpa, std.mem.asBytes(&std.mem.nativeToLittle(u32, word)));
    var page: [memory.page]u8 = @splat(0);
    @memcpy(page[0..bytes.len], bytes);
    try out.appendSlice(gpa, &page);
}

fn emptyRegionSection(out: *std.ArrayList(u8), base: u32) !void {
    for ([_]u32{ 1, base, memory.page, 0 }) |word| try out.appendSlice(gpa, std.mem.asBytes(&std.mem.nativeToLittle(u32, word)));
}

/// An ELF with a read-only code segment at `rom_base` and an initialised
/// data segment that runs in RAM and is loaded at `flash_copy`.
fn image(out: *std.ArrayList(u8), code: u8, data: u8) !void {
    var head = std.mem.zeroes(elf.Header);
    head.magic = "\x7fELF".*;
    head.class = 1;
    head.data = 1;
    head.e_machine = elf.em_arm;
    head.e_phoff = @sizeOf(elf.Header);
    head.e_phentsize = @sizeOf(elf.ProgramHeader);
    head.e_phnum = 2;
    const body = @sizeOf(elf.Header) + 2 * @sizeOf(elf.ProgramHeader);
    const loads = [_]elf.ProgramHeader{
        .{ .p_type = elf.pt_load, .p_offset = body, .p_vaddr = rom_base, .p_paddr = rom_base, .p_filesz = 4, .p_memsz = 4, .p_flags = 5, .p_align = 4 },
        .{ .p_type = elf.pt_load, .p_offset = body + 4, .p_vaddr = ram_base, .p_paddr = flash_copy, .p_filesz = 4, .p_memsz = 4, .p_flags = 6, .p_align = 4 },
    };
    try out.appendSlice(gpa, std.mem.asBytes(&head));
    for (loads) |load| try out.appendSlice(gpa, std.mem.asBytes(&load));
    try out.appendSlice(gpa, &[_]u8{ code, code, code, code, data, data, data, data });
}

fn singleSegImage(out: *std.ArrayList(u8), vaddr: u32, paddr: u32, filesz: u32, memsz: u32, flags: u32, fill: u8) !void {
    var head = std.mem.zeroes(elf.Header);
    head.magic = "\x7fELF".*;
    head.class = 1;
    head.data = 1;
    head.e_machine = elf.em_arm;
    head.e_phoff = @sizeOf(elf.Header);
    head.e_phentsize = @sizeOf(elf.ProgramHeader);
    head.e_phnum = 1;
    const body = @sizeOf(elf.Header) + @sizeOf(elf.ProgramHeader);
    const load = elf.ProgramHeader{
        .p_type = elf.pt_load,
        .p_offset = body,
        .p_vaddr = vaddr,
        .p_paddr = paddr,
        .p_filesz = filesz,
        .p_memsz = memsz,
        .p_flags = flags,
        .p_align = 4,
    };
    try out.appendSlice(gpa, std.mem.asBytes(&head));
    try out.appendSlice(gpa, std.mem.asBytes(&load));
    try out.appendNTimes(gpa, fill, filesz);
}

const Sides = struct {
    original: std.ArrayList(u8) = .empty,
    rebuilt: std.ArrayList(u8) = .empty,

    fn deinit(self: *Sides) void {
        self.original.deinit(gpa);
        self.rebuilt.deinit(gpa);
    }
};

const Compare = struct { spot: ?memory.Spot, same_hash: bool };

fn compareRawSections(a_bytes: []const u8, b_bytes: []const u8, mask: memory.Mask) !Compare {
    const parsed_a = try memory.parse(a_bytes);
    const parsed_b = try memory.parse(b_bytes);
    var ha = std.crypto.hash.Blake3.init(.{});
    var hb = std.crypto.hash.Blake3.init(.{});
    memory.hash(&ha, parsed_a, mask);
    memory.hash(&hb, parsed_b, mask.flipped());
    var da: [16]u8 = undefined;
    var db: [16]u8 = undefined;
    ha.final(&da);
    hb.final(&db);
    return .{ .spot = memory.firstDifference(parsed_a, parsed_b, mask), .same_hash = std.mem.eql(u8, &da, &db) };
}

/// The first difference between two runs' memory, and whether they hash
/// alike, with each run's image built from its code and initial data bytes.
fn compare(base: u32, left: []const u8, right: []const u8, code: [2]u8, data: [2]u8) !Compare {
    var images: Sides = .{};
    defer images.deinit();
    try image(&images.original, code[0], data[0]);
    try image(&images.rebuilt, code[1], data[1]);
    const mask: memory.Mask = .{ .a = try elf.Image.init(images.original.items), .b = try elf.Image.init(images.rebuilt.items) };
    var a: std.ArrayList(u8) = .empty;
    defer a.deinit(gpa);
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    try section(&a, base, left);
    try section(&b, base, right);
    return compareRawSections(a.items, b.items, mask);
}

test "a rebuilt image's own code and flash copy are not a difference" {
    const code = try compare(rom_base, &.{ 1, 1, 1, 1 }, &.{ 2, 2, 2, 2 }, .{ 1, 2 }, .{ 0, 0 });
    try std.testing.expectEqual(@as(?memory.Spot, null), code.spot);
    try std.testing.expect(code.same_hash);
    const copy = try compare(flash_copy, &.{ 7, 7, 7, 7 }, &.{ 8, 8, 8, 8 }, .{ 0, 0 }, .{ 7, 8 });
    try std.testing.expectEqual(@as(?memory.Spot, null), copy.spot);
    try std.testing.expect(copy.same_hash);
}

test "a different initial value of a variable in RAM is a difference" {
    const out = try compare(ram_base, &.{ 5, 0, 0, 0 }, &.{ 6, 0, 0, 0 }, .{ 0, 0 }, .{ 5, 6 });
    try std.testing.expectEqual(memory.Spot{ .address = ram_base, .expected = 5, .actual = 6 }, out.spot.?);
    try std.testing.expect(!out.same_hash);
}

test "an initialiser that both runs wrote the same value over is not a difference" {
    const out = try compare(ram_base, &.{ 9, 0, 0, 0 }, &.{ 9, 0, 0, 0 }, .{ 0, 0 }, .{ 5, 6 });
    try std.testing.expectEqual(@as(?memory.Spot, null), out.spot);
    try std.testing.expect(out.same_hash);
}

test "two writes that only look alike against their own loads are a difference" {
    const out = try compare(ram_base, &.{ 9, 0, 0, 0 }, &.{ 10, 0, 0, 0 }, .{ 0, 0 }, .{ 5, 6 });
    try std.testing.expectEqual(memory.Spot{ .address = ram_base, .expected = 9, .actual = 10 }, out.spot.?);
    try std.testing.expect(!out.same_hash);
}

test "post-load guest writes to read-only code or load-copy bytes diverge with exact Spot" {
    // Rebuilt run mutates byte +2 of its RAM-resident read-only code segment from 2 to 0x99.
    const ro_write = try compare(rom_base, &.{ 1, 1, 1, 1 }, &.{ 2, 2, 0x99, 2 }, .{ 1, 2 }, .{ 0, 0 });
    try std.testing.expectEqual(memory.Spot{ .address = rom_base + 2, .expected = 1, .actual = 0x99 }, ro_write.spot.?);
    try std.testing.expect(!ro_write.same_hash);

    // Rebuilt run mutates byte +1 of its load-copy source from 8 to 0x55.
    const lma_write = try compare(flash_copy, &.{ 7, 7, 7, 7 }, &.{ 8, 0x55, 8, 8 }, .{ 0, 0 }, .{ 7, 8 });
    try std.testing.expectEqual(memory.Spot{ .address = flash_copy + 1, .expected = 7, .actual = 0x55 }, lma_write.spot.?);
    try std.testing.expect(!lma_write.same_hash);
}

test "zero-wiping a read-only page post-load diverges instead of skipping as clean" {
    var images: Sides = .{};
    defer images.deinit();
    try image(&images.original, 0x42, 0);
    try image(&images.rebuilt, 0x42, 0);
    const mask: memory.Mask = .{ .a = try elf.Image.init(images.original.items), .b = try elf.Image.init(images.rebuilt.items) };

    var a: std.ArrayList(u8) = .empty;
    defer a.deinit(gpa);
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    try section(&a, rom_base, &.{ 0x42, 0x42, 0x42, 0x42 });
    // Rebuilt run zero-wiped the entire 4 KiB page so the save stream omitted the zero page.
    try emptyRegionSection(&b, rom_base);

    const out = try compareRawSections(a.items, b.items, mask);
    try std.testing.expectEqual(memory.Spot{ .address = rom_base, .expected = 0x42, .actual = 0 }, out.spot.?);
    try std.testing.expect(!out.same_hash);
}

test "extra unmutated read-only ITCM window in rebuilt ELF hashes and compares compatible" {
    var images: Sides = .{};
    defer images.deinit();
    try singleSegImage(&images.original, 0x1000, 0x1000, 8, 8, 5, 0x11);
    // Rebuilt ELF grew into a second dynamic ITCM page at 0x2000.
    var head = std.mem.zeroes(elf.Header);
    head.magic = "\x7fELF".*;
    head.class = 1;
    head.data = 1;
    head.e_machine = elf.em_arm;
    head.e_phoff = @sizeOf(elf.Header);
    head.e_phentsize = @sizeOf(elf.ProgramHeader);
    head.e_phnum = 2;
    const body = @sizeOf(elf.Header) + 2 * @sizeOf(elf.ProgramHeader);
    const loads = [_]elf.ProgramHeader{
        .{ .p_type = elf.pt_load, .p_offset = body, .p_vaddr = 0x1000, .p_paddr = 0x1000, .p_filesz = 8, .p_memsz = 8, .p_flags = 5, .p_align = 4 },
        .{ .p_type = elf.pt_load, .p_offset = body + 8, .p_vaddr = 0x2000, .p_paddr = 0x2000, .p_filesz = 8, .p_memsz = 8, .p_flags = 5, .p_align = 4 },
    };
    try images.rebuilt.appendSlice(gpa, std.mem.asBytes(&head));
    for (loads) |load| try images.rebuilt.appendSlice(gpa, std.mem.asBytes(&load));
    try images.rebuilt.appendNTimes(gpa, 0x22, 16);

    const mask: memory.Mask = .{ .a = try elf.Image.init(images.original.items), .b = try elf.Image.init(images.rebuilt.items) };
    var a: std.ArrayList(u8) = .empty;
    defer a.deinit(gpa);
    try section(&a, 0x1000, &@as([8]u8, @splat(0x11)));

    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    // Two dynamic extra regions in rebuilt save stream (0x1000 and 0x2000).
    try b.appendSlice(gpa, std.mem.asBytes(&std.mem.nativeToLittle(u32, 2)));
    for ([_]u32{ 0x1000, memory.page, 1, 0 }) |w| try b.appendSlice(gpa, std.mem.asBytes(&std.mem.nativeToLittle(u32, w)));
    var p1: [memory.page]u8 = @splat(0);
    @memset(p1[0..8], 0x22);
    try b.appendSlice(gpa, &p1);
    for ([_]u32{ 0x2000, memory.page, 1, 0 }) |w| try b.appendSlice(gpa, std.mem.asBytes(&std.mem.nativeToLittle(u32, w)));
    try b.appendSlice(gpa, &p1);

    const clean = try compareRawSections(a.items, b.items, mask);
    try std.testing.expectEqual(@as(?memory.Spot, null), clean.spot);
    try std.testing.expect(clean.same_hash);

    // Mutate one byte inside the rebuilt extra page at 0x2003 -> must diverge!
    b.items[b.items.len - memory.page + 3] = 0x77;
    const dirty = try compareRawSections(a.items, b.items, mask);
    try std.testing.expectEqual(memory.Spot{ .address = 0x2003, .expected = 0, .actual = 0x77 }, dirty.spot.?);
    try std.testing.expect(!dirty.same_hash);
}

test "Non-Secure alias RO segment normalizes to canonical SRAM and catches post-load writes" {
    var images: Sides = .{};
    defer images.deinit();
    try singleSegImage(&images.original, memmap.ns_sram_base, memmap.ns_sram_base, 4, 4, 4, 0xAA);
    try singleSegImage(&images.rebuilt, memmap.ns_sram_base, memmap.ns_sram_base, 4, 4, 4, 0xBB);
    const mask: memory.Mask = .{ .a = try elf.Image.init(images.original.items), .b = try elf.Image.init(images.rebuilt.items) };

    var a: std.ArrayList(u8) = .empty;
    defer a.deinit(gpa);
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    try section(&a, memmap.sram_base, &.{ 0xAA, 0xAA, 0xAA, 0xAA });
    try section(&b, memmap.sram_base, &.{ 0xBB, 0xBB, 0xBB, 0xBB });
    const ok = try compareRawSections(a.items, b.items, mask);
    try std.testing.expectEqual(@as(?memory.Spot, null), ok.spot);
    try std.testing.expect(ok.same_hash);

    b.items[b.items.len - memory.page + 1] = 0xCC;
    const bad = try compareRawSections(a.items, b.items, mask);
    try std.testing.expectEqual(memory.Spot{ .address = memmap.sram_base + 1, .expected = 0xAA, .actual = 0xCC }, bad.spot.?);
    try std.testing.expect(!bad.same_hash);
}

test "RO in original overlapping writable .bss in rebuilt compares raw" {
    var images: Sides = .{};
    defer images.deinit();
    try singleSegImage(&images.original, memmap.sram_base, memmap.sram_base, 4, 4, 4, 0x33);
    // Rebuilt places a zero-initialized writable .bss (filesz = 0, memsz = 4, flags = RW) at sram_base.
    try singleSegImage(&images.rebuilt, memmap.sram_base, memmap.sram_base, 0, 4, 6, 0);
    const mask: memory.Mask = .{ .a = try elf.Image.init(images.original.items), .b = try elf.Image.init(images.rebuilt.items) };

    var a: std.ArrayList(u8) = .empty;
    defer a.deinit(gpa);
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    try section(&a, memmap.sram_base, &.{ 0x33, 0x33, 0x33, 0x33 });
    try section(&b, memmap.sram_base, &.{ 0, 0, 0, 0 });
    const out = try compareRawSections(a.items, b.items, mask);
    try std.testing.expectEqual(memory.Spot{ .address = memmap.sram_base, .expected = 0x33, .actual = 0 }, out.spot.?);
    try std.testing.expect(!out.same_hash);
}
