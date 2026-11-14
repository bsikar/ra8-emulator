//! A minimal ELF32 ARM image carrying one symbol table, built byte by byte
//! so a test owns every offset in it. Shared by the symbol reader's tests
//! and by the report tests that resolve a global through it.
const std = @import("std");
const ra8 = @import("ra8");
const elf = ra8.board.image.elf;
const symbols = ra8.session.symbols;

/// A minimal ELF32 ARM image with one symbol table and one string table,
/// built byte by byte so the test owns every offset in it.
pub const Builder = struct {
    /// Layout: header, then three section headers, then the two tables.
    pub const header_len = @sizeOf(elf.Header);
    pub const shent = @sizeOf(symbols.SectionHeader);
    pub const sh_count = 3;
    pub const sh_off = header_len;
    pub const sym_off = sh_off + shent * sh_count;

    pub fn build(buffer: []u8, names: []const []const u8, values: []const u32) []u8 {
        return buildSized(buffer, names, values, null);
    }

    /// The same image with sized function symbols: st_size and STT_FUNC set,
    /// so the relative-name lookups can see function extents.
    pub fn buildSized(buffer: []u8, names: []const []const u8, values: []const u32, sizes: ?[]const u32) []u8 {
        @memset(buffer, 0);
        // The string table: a leading null, then each name terminated.
        var strings: std.ArrayListUnmanaged(u8) = .empty;
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
            if (sizes) |given| {
                entry.st_size = given[index];
                entry.st_info = symbols.symbol_type.func;
            }
        }
        @memcpy(buffer[str_off..][0..strings.items.len], strings.items);
        return buffer[0 .. str_off + strings.items.len];
    }

    /// The same image with a debug-info trio appended: `.debug_info`,
    /// `.debug_abbrev` and `.debug_str` carry the bytes a DWARF test
    /// hands in, and a `.shstrtab` names every section so the DWARF
    /// readers can find them by name.
    pub fn buildDebug(buffer: []u8, names: []const []const u8, values: []const u32, info: []const u8, abbrev: []const u8, str: []const u8) []u8 {
        @memset(buffer, 0);
        var strings: std.ArrayListUnmanaged(u8) = .empty;
        var offsets: [8]u32 = undefined;
        var backing: [512]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&backing);
        strings.append(fba.allocator(), 0) catch unreachable;
        for (names, 0..) |name, index| {
            offsets[index] = @intCast(strings.items.len);
            strings.appendSlice(fba.allocator(), name) catch unreachable;
            strings.append(fba.allocator(), 0) catch unreachable;
        }
        // Seven headers (NULL, symtab, strtab, three debug, shstrtab) come
        // before the symbol data, so the layout starts after all of them.
        const table_off: u32 = sh_off + shent * 7;
        const sym_len: u32 = @intCast(@sizeOf(symbols.Symbol) * names.len);
        const str_off: u32 = table_off + sym_len;
        const info_off: u32 = str_off + @as(u32, @intCast(strings.items.len));
        const abbrev_off: u32 = info_off + @as(u32, @intCast(info.len));
        const str_sec_off: u32 = abbrev_off + @as(u32, @intCast(abbrev.len));
        const shstr_off: u32 = str_sec_off + @as(u32, @intCast(str.len));
        const shstr = "\x00.symtab\x00.strtab\x00.debug_info\x00.debug_abbrev\x00.debug_str\x00.shstrtab\x00";
        const end: u32 = shstr_off + @as(u32, @intCast(shstr.len));

        const head: *align(1) elf.Header = std.mem.bytesAsValue(elf.Header, buffer[0..header_len]);
        head.magic = .{ 0x7F, 'E', 'L', 'F' };
        head.class = 1;
        head.data = 1;
        head.e_machine = elf.em_arm;
        head.e_shoff = sh_off;
        head.e_shentsize = shent;
        head.e_shnum = 7;
        head.e_phnum = 0;
        head.e_shstrndx = 6;

        const table: *align(1) symbols.SectionHeader =
            std.mem.bytesAsValue(symbols.SectionHeader, buffer[sh_off + shent ..][0..shent]);
        table.sh_type = symbols.section_type.symtab;
        table.sh_offset = table_off;
        table.sh_size = @intCast(sym_len);
        table.sh_entsize = @sizeOf(symbols.Symbol);
        table.sh_link = 2;
        table.sh_name = 1;

        const strings_head: *align(1) symbols.SectionHeader =
            std.mem.bytesAsValue(symbols.SectionHeader, buffer[sh_off + shent * 2 ..][0..shent]);
        strings_head.sh_type = 3;
        strings_head.sh_offset = @intCast(str_off);
        strings_head.sh_size = @intCast(strings.items.len);
        strings_head.sh_name = 9;

        section(buffer, 3, 1, info_off, info.len, 17);
        section(buffer, 4, 1, abbrev_off, abbrev.len, 29);
        section(buffer, 5, 1, str_sec_off, str.len, 43);
        section(buffer, 6, 3, shstr_off, shstr.len, 54);

        for (names, 0..) |_, index| {
            const at = table_off + @sizeOf(symbols.Symbol) * index;
            const entry: *align(1) symbols.Symbol =
                std.mem.bytesAsValue(symbols.Symbol, buffer[at..][0..@sizeOf(symbols.Symbol)]);
            entry.st_name = offsets[index];
            entry.st_value = values[index];
        }
        @memcpy(buffer[str_off..][0..strings.items.len], strings.items);
        @memcpy(buffer[info_off..][0..info.len], info);
        @memcpy(buffer[abbrev_off..][0..abbrev.len], abbrev);
        @memcpy(buffer[str_sec_off..][0..str.len], str);
        @memcpy(buffer[shstr_off..][0..shstr.len], shstr);
        return buffer[0..end];
    }

    fn section(buffer: []u8, index: usize, kind: u32, offset: u32, size: usize, name: u32) void {
        const head = std.mem.bytesAsValue(symbols.SectionHeader, buffer[sh_off + shent * index ..][0..shent]);
        head.sh_type = kind;
        head.sh_offset = offset;
        head.sh_size = @intCast(size);
        head.sh_name = name;
    }
};
