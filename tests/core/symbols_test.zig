//! The symbol table reader: a global's address by name, and the shapes of
//! image that carry no answer.
const std = @import("std");
const ra8 = @import("ra8");
const elf = ra8.core.elf;
const symbols = ra8.core.symbols;

/// A minimal ELF32 ARM image with one symbol table and one string table,
/// built byte by byte so the test owns every offset in it.
const Builder = struct {
    /// Layout: header, then three section headers, then the two tables.
    const header_len = @sizeOf(elf.Header);
    const shent = @sizeOf(symbols.SectionHeader);
    const sh_count = 3;
    const sh_off = header_len;
    const sym_off = sh_off + shent * sh_count;

    fn build(buffer: []u8, names: []const []const u8, values: []const u32) []u8 {
        @memset(buffer, 0);
        // The string table: a leading null, then each name terminated.
        var strings = std.ArrayListUnmanaged(u8){};
        var offsets: [8]u32 = undefined;
        var backing: [512]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&backing);
        strings.append(fba.allocator(), 0) catch unreachable;
        for (names, 0..) |name, index| {
            offsets[index] = @intCast(strings.items.len);
            strings.appendSlice(fba.allocator(), name) catch unreachable;
            strings.append(fba.allocator(), 0) catch unreachable;
        }
        const sym_len = @sizeOf(symbols.Symbol) * names.len;
        const str_off = sym_off + sym_len;

        const head: *align(1) elf.Header = std.mem.bytesAsValue(elf.Header, buffer[0..header_len]);
        head.magic = .{ 0x7F, 'E', 'L', 'F' };
        head.class = 1;
        head.data = 1;
        head.e_machine = elf.em_arm;
        head.e_shoff = sh_off;
        head.e_shentsize = shent;
        head.e_shnum = sh_count;
        head.e_phnum = 0;

        // Section 1 is the symbol table, linking to section 2, the strings.
        const one: *align(1) symbols.SectionHeader =
            std.mem.bytesAsValue(symbols.SectionHeader, buffer[sh_off + shent ..][0..shent]);
        one.sh_type = symbols.section_type.symtab;
        one.sh_offset = sym_off;
        one.sh_size = @intCast(sym_len);
        one.sh_entsize = @sizeOf(symbols.Symbol);
        one.sh_link = 2;

        const two: *align(1) symbols.SectionHeader =
            std.mem.bytesAsValue(symbols.SectionHeader, buffer[sh_off + shent * 2 ..][0..shent]);
        two.sh_type = 3;
        two.sh_offset = @intCast(str_off);
        two.sh_size = @intCast(strings.items.len);

        for (names, 0..) |_, index| {
            const at = sym_off + @sizeOf(symbols.Symbol) * index;
            const entry: *align(1) symbols.Symbol =
                std.mem.bytesAsValue(symbols.Symbol, buffer[at..][0..@sizeOf(symbols.Symbol)]);
            entry.st_name = offsets[index];
            entry.st_value = values[index];
        }
        @memcpy(buffer[str_off..][0..strings.items.len], strings.items);
        return buffer[0 .. str_off + strings.items.len];
    }
};

test "a named global resolves to its address" {
    var buffer: [1024]u8 = undefined;
    const bytes = Builder.build(
        &buffer,
        &.{ "g_ticks", "g_faults" },
        &.{ 0x2200_0100, 0x2200_0200 },
    );
    const image = try elf.Image.init(bytes);
    try std.testing.expectEqual(@as(?u32, 0x2200_0100), symbols.addressOf(image, "g_ticks"));
    try std.testing.expectEqual(@as(?u32, 0x2200_0200), symbols.addressOf(image, "g_faults"));
}

test "a name the image does not carry resolves to nothing" {
    var buffer: [1024]u8 = undefined;
    const bytes = Builder.build(&buffer, &.{"g_ticks"}, &.{0x2200_0100});
    const image = try elf.Image.init(bytes);
    try std.testing.expectEqual(@as(?u32, null), symbols.addressOf(image, "g_missing"));
}

test "a prefix of a real name is not that name" {
    var buffer: [1024]u8 = undefined;
    const bytes = Builder.build(&buffer, &.{"g_ticks"}, &.{0x2200_0100});
    const image = try elf.Image.init(bytes);
    try std.testing.expectEqual(@as(?u32, null), symbols.addressOf(image, "g_tick"));
    try std.testing.expectEqual(@as(?u32, null), symbols.addressOf(image, "g_ticks_more"));
}

test "the table is counted, not guessed at" {
    var buffer: [1024]u8 = undefined;
    const bytes = Builder.build(
        &buffer,
        &.{ "g_a", "g_b", "g_c" },
        &.{ 1, 2, 3 },
    );
    const image = try elf.Image.init(bytes);
    try std.testing.expectEqual(@as(usize, 3), symbols.count(image));
}

test "an image with no section headers at all carries no symbols" {
    var buffer: [@sizeOf(elf.Header)]u8 = undefined;
    @memset(&buffer, 0);
    const head: *align(1) elf.Header = std.mem.bytesAsValue(elf.Header, &buffer);
    head.magic = .{ 0x7F, 'E', 'L', 'F' };
    head.class = 1;
    head.data = 1;
    head.e_machine = elf.em_arm;
    const image = try elf.Image.init(&buffer);
    try std.testing.expectEqual(@as(usize, 0), symbols.count(image));
    try std.testing.expectEqual(@as(?u32, null), symbols.addressOf(image, "g_ticks"));
}

test "a section header index past the table is not a section" {
    var buffer: [1024]u8 = undefined;
    const bytes = Builder.build(&buffer, &.{"g_ticks"}, &.{0x2200_0100});
    const image = try elf.Image.init(bytes);
    try std.testing.expect(symbols.section(image, 0) != null);
    try std.testing.expect(symbols.section(image, 3) == null);
}

test "a symbol table running off the end of the file is refused" {
    var buffer: [1024]u8 = undefined;
    const bytes = Builder.build(&buffer, &.{"g_ticks"}, &.{0x2200_0100});
    const image = try elf.Image.init(bytes);
    const one: *align(1) symbols.SectionHeader = @constCast(symbols.section(image, 1).?);
    one.sh_size = 0xFFFF_0000;
    try std.testing.expectEqual(@as(?u32, null), symbols.addressOf(image, "g_ticks"));
}

test "a symbol table naming a string table that is not there is refused" {
    var buffer: [1024]u8 = undefined;
    const bytes = Builder.build(&buffer, &.{"g_ticks"}, &.{0x2200_0100});
    const image = try elf.Image.init(bytes);
    const one: *align(1) symbols.SectionHeader = @constCast(symbols.section(image, 1).?);
    one.sh_link = 9;
    try std.testing.expectEqual(@as(?u32, null), symbols.addressOf(image, "g_ticks"));
}

test "a global the linker placed at zero is found there, not reported missing" {
    var buffer: [1024]u8 = undefined;
    const bytes = Builder.build(&buffer, &.{"g_zero"}, &.{0});
    const image = try elf.Image.init(bytes);
    try std.testing.expectEqual(@as(?u32, 0), symbols.addressOf(image, "g_zero"));
}
