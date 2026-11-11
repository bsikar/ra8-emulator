//! A save stream's memory section as the bytes the two runs hold.
//!
//! The loader writes an image's code and constants into guest memory, so a
//! rebuilt image differs from the recorded one in those bytes before a
//! single instruction has run. At addresses where either image loaded
//! read-only or load-copy bytes (and neither placed an in-place writable
//! variable), each stream compares against its own loaded initial byte (or
//! the backing region's reset byte where only the peer image loaded bytes):
//! an unmutated initial byte normalises to clean, while any post-load guest
//! write—whether to RAM-resident code, constants, load-copy data or an
//! erased page—marks the cell mutated with the byte held there. Everywhere
//! else, bytes compare raw as held.
const std = @import("std");
const elf = @import("ra8_board").image.elf;
const memmap = @import("ra8_chip").core.memmap;
const external_port = @import("ra8_chip").core.cpu.memory.external_port;
const option_window = @import("ra8_chip").periph.mram.option_window;

pub const page: u32 = 0x1000;
pub const max_regions: usize = 48;
pub const ospi_base: u32 = external_port.Kind.ospi.base();
pub const ospi_max: u32 = external_port.ospi_max;

pub const Error = error{ Truncated, BadValue };

/// One saved region: its pages are the `count` offset-and-bytes entries
/// that start at `pages`.
pub const Region = struct {
    base: u32,
    len: u32,
    count: u32,
    pages: []const u8,
};

/// The regions of a memory section and the bytes after them.
pub const Parsed = struct {
    regions: [max_regions]Region = undefined,
    len: usize = 0,
    tail: []const u8 = &.{},

    pub fn list(self: *const Parsed) []const Region {
        return self.regions[0..self.len];
    }
};

fn int(payload: []const u8, at: *usize) Error!u32 {
    if (payload.len - at.* < 4) return Error.Truncated;
    defer at.* += 4;
    return std.mem.readInt(u32, payload[at.*..][0..4], .little);
}

pub fn parse(payload: []const u8) Error!Parsed {
    var out: Parsed = .{};
    var at: usize = 0;
    const count = try int(payload, &at);
    if (count > max_regions) return Error.BadValue;
    for (0..count) |_| {
        const base = try int(payload, &at);
        const len = try int(payload, &at);
        const pages = try int(payload, &at);
        const start = at;
        for (0..pages) |_| {
            const offset = try int(payload, &at);
            if (offset >= len) return Error.BadValue;
            const size: usize = @min(page, len - offset);
            if (payload.len - at < size) return Error.Truncated;
            at += size;
        }
        out.regions[out.len] = .{ .base = base, .len = len, .count = pages, .pages = payload[start..at] };
        out.len += 1;
    }
    out.tail = payload[at..];
    return out;
}

const pf_w: u32 = 2;

/// Folds Non-Secure alias addresses onto the canonical Secure backing base
/// that snapshots store.
pub fn canonical(address: u32) u32 {
    if (address >= memmap.ns_mram_base and address < memmap.ns_mram_end) return address - memmap.ns_offset;
    if (address >= memmap.ns_sram_base and address < memmap.ns_sram_end) return address - memmap.ns_offset;
    if (address >= external_port.sdram_alias_base and address < external_port.sdram_alias_base + external_port.sdram_max) {
        return address - memmap.ns_offset;
    }
    return address;
}

fn hasNsAlias(canon: u32) bool {
    return (canon >= memmap.mram_base and canon < memmap.mram_end) or
        (canon >= memmap.sram_base and canon < memmap.sram_end) or
        (canon >= memmap.sdram_base and canon < memmap.sdram_base + external_port.sdram_max);
}

/// The byte value a backing cell holds before any image segment writes it.
pub fn resetByte(canon: u32) u8 {
    if (canon >= option_window.span.base and canon < option_window.span.end) return 0xFF;
    if (canon >= ospi_base and canon < ospi_base + ospi_max) return 0xFF;
    return 0;
}

const ImageAt = union(enum) { none, writable, own: u8 };

fn programHeader(image: elf.Image, index: u16) ?*align(1) const elf.ProgramHeader {
    const head = image.header();
    if (index >= head.e_phnum or head.e_phentsize < @sizeOf(elf.ProgramHeader)) return null;
    const start = @as(usize, head.e_phoff) + @as(usize, index) * @as(usize, head.e_phentsize);
    if (start + @sizeOf(elf.ProgramHeader) > image.bytes.len) return null;
    const ph: *align(1) const elf.ProgramHeader = std.mem.bytesAsValue(elf.ProgramHeader, image.bytes[start..][0..@sizeOf(elf.ProgramHeader)]);
    return if (ph.p_type == elf.pt_load) ph else null;
}

fn hitOffset(seg_base: u32, seg_len: u32, canon: u32) ?usize {
    const end = @as(u64, seg_base) + seg_len;
    if (canon >= seg_base and @as(u64, canon) < end) return @intCast(canon - seg_base);
    if (hasNsAlias(canon)) {
        const alias = canon + memmap.ns_offset;
        if (alias >= seg_base and @as(u64, alias) < end) return @intCast(alias - seg_base);
    }
    return null;
}

fn spanOverlaps(seg_base: u32, seg_len: u32, canon_base: u32, size: u32) bool {
    if (seg_len == 0 or size == 0) return false;
    const s0: u64 = seg_base;
    const s1: u64 = s0 + seg_len;
    const a0: u64 = canon_base;
    if (a0 < s1 and a0 + size > s0) return true;
    if (hasNsAlias(canon_base)) {
        const b0: u64 = canon_base + memmap.ns_offset;
        if (b0 < s1 and b0 + size > s0) return true;
    }
    return false;
}

/// How `image` populates canonical `canon`: last covering PT_LOAD wins,
/// matching loader order.
fn imageAt(image: elf.Image, canon: u32) ImageAt {
    var i: u16 = image.segmentCount();
    while (i > 0) {
        i -= 1;
        const ph = programHeader(image, i) orelse continue;
        if (ph.p_filesz > 0) {
            if (hitOffset(ph.p_paddr, ph.p_filesz, canon)) |off| {
                const pos = @as(usize, ph.p_offset) + off;
                if (pos >= image.bytes.len) continue;
                if (ph.p_flags & pf_w == 0 or ph.p_paddr != ph.p_vaddr) return .{ .own = image.bytes[pos] };
                return .writable;
            }
        }
        if (ph.p_flags & pf_w != 0 and ph.p_paddr == ph.p_vaddr and ph.p_memsz > ph.p_filesz) {
            if (hitOffset(ph.p_paddr, ph.p_memsz, canon) != null) return .writable;
        }
    }
    return .none;
}

pub fn overlapsLoaded(image: elf.Image, canon_base: u32, size: u32) bool {
    var i: u16 = 0;
    while (i < image.segmentCount()) : (i += 1) {
        const ph = programHeader(image, i) orelse continue;
        if (spanOverlaps(ph.p_paddr, ph.p_filesz, canon_base, size)) return true;
    }
    return false;
}

fn overlapsOwn(image: elf.Image, canon_base: u32, size: u32) bool {
    var i: u16 = 0;
    while (i < image.segmentCount()) : (i += 1) {
        const ph = programHeader(image, i) orelse continue;
        if (ph.p_flags & pf_w == 0 or ph.p_paddr != ph.p_vaddr) {
            if (spanOverlaps(ph.p_paddr, ph.p_filesz, canon_base, size)) return true;
        }
    }
    return false;
}

fn overlapsWritable(image: elf.Image, canon_base: u32, size: u32) bool {
    var i: u16 = 0;
    while (i < image.segmentCount()) : (i += 1) {
        const ph = programHeader(image, i) orelse continue;
        if (ph.p_flags & pf_w != 0 and ph.p_paddr == ph.p_vaddr) {
            const span = @max(ph.p_filesz, ph.p_memsz);
            if (spanOverlaps(ph.p_paddr, span, canon_base, size)) return true;
        }
    }
    return false;
}

/// Normalized observation of one guest byte under `Mask`.
pub const Cell = struct {
    mutated: bool = false,
    byte: u8 = 0,

    pub fn eql(self: Cell, other: Cell) bool {
        return self.mutated == other.mutated and self.byte == other.byte;
    }
};

/// Image pair for memory comparison: `a` is this stream's image (`expected`
/// in two-stream calls) and `b` is the peer stream's image (`actual`).
pub const Mask = struct {
    a: ?elf.Image,
    b: ?elf.Image,

    pub fn flipped(self: Mask) Mask {
        return .{ .a = self.b, .b = self.a };
    }

    /// Only CPU0 is rebuilt. CPU1's original bytes compare without any
    /// exclusions, including private addresses covered by CPU0's image.
    pub fn forCore(self: Mask, core: u8) Mask {
        return if (core == 0) self else .{ .a = null, .b = null };
    }

    /// Whether `address` sits in the read-only / load-copy domain where
    /// unmutated image bytes are normalized and post-load writes are flagged.
    pub fn skips(self: Mask, address: u32) bool {
        const canon = canonical(address);
        const va = if (self.a) |img| imageAt(img, canon) else .none;
        const vb = if (self.b) |img| imageAt(img, canon) else .none;
        if (va == .writable or vb == .writable) return false;
        return va == .own or vb == .own;
    }

    pub fn cell(self: Mask, address: u32, saved_byte: u8) Cell {
        const canon = canonical(address);
        const va = if (self.a) |img| imageAt(img, canon) else .none;
        const vb = if (self.b) |img| imageAt(img, canon) else .none;
        if (va == .writable or vb == .writable or (va == .none and vb == .none)) {
            return .{ .mutated = false, .byte = saved_byte };
        }
        const init: u8 = switch (va) {
            .own => |loaded| loaded,
            else => resetByte(canon),
        };
        if (saved_byte == init) return .{ .mutated = false, .byte = 0 };
        return .{ .mutated = true, .byte = saved_byte };
    }

    fn zeroPageClean(self: Mask, base: u32, size: u32) bool {
        const canon = canonical(base);
        const end: u64 = @as(u64, canon) + size;
        if (canon < option_window.span.end and end > option_window.span.base) return false;
        if (self.a) |img| if (overlapsLoaded(img, canon, size)) return false;
        return true;
    }

    /// Whether `[base, base + len)` is a dynamic extra window mapped solely
    /// for an image's read-only or load-copy segment.
    fn isOwnExtraWindow(self: Mask, base: u32, len: u32) bool {
        if (memmap.coversRam(base, len) or option_window.covers(base, len)) return false;
        if (base >= memmap.sdram_base and @as(u64, base) + len <= memmap.sdram_base + external_port.sdram_max) return false;
        const canon = canonical(base);
        if (self.a) |img| if (overlapsWritable(img, canon, len)) return false;
        if (self.b) |img| if (overlapsWritable(img, canon, len)) return false;
        const own_a = if (self.a) |img| overlapsOwn(img, canon, len) else false;
        const own_b = if (self.b) |img| overlapsOwn(img, canon, len) else false;
        return own_a or own_b;
    }
};

/// Walks a region's saved pages in offset order.
pub const Pages = struct {
    rest: []const u8,
    len: u32,

    pub fn init(region: Region) Pages {
        return .{ .rest = region.pages, .len = region.len };
    }

    pub fn next(self: *Pages) ?struct { offset: u32, bytes: []const u8 } {
        if (self.rest.len == 0) return null;
        const offset = std.mem.readInt(u32, self.rest[0..4], .little);
        const size: usize = @min(page, self.len - offset);
        const bytes = self.rest[4..][0..size];
        self.rest = self.rest[4 + size ..];
        return .{ .offset = offset, .bytes = bytes };
    }
};

pub fn saved(region: Region, offset: u32) ?[]const u8 {
    var pages = Pages.init(region);
    while (pages.next()) |entry| {
        if (entry.offset == offset) return entry.bytes;
        if (entry.offset > offset) return null;
    }
    return null;
}

pub const Spot = struct { address: u32, expected: u8, actual: u8 };

fn sortedRegions(parsed: Parsed) struct { items: [max_regions]Region, len: usize } {
    var out: [max_regions]Region = undefined;
    @memcpy(out[0..parsed.len], parsed.list());
    std.mem.sort(Region, out[0..parsed.len], {}, struct {
        fn less(_: void, x: Region, y: Region) bool {
            return x.base < y.base;
        }
    }.less);
    return .{ .items = out, .len = parsed.len };
}

fn diffRegions(a: ?Region, b: ?Region, mask: Mask) ?Spot {
    const base = if (a) |ra| ra.base else b.?.base;
    const len = @max(if (a) |ra| ra.len else 0, if (b) |rb| rb.len else 0);
    const peer = mask.flipped();
    var offset: u32 = 0;
    while (offset < len) : (offset += page) {
        const size: u32 = @min(page, len - offset);
        const in_a = if (a) |ra| (if (offset < ra.len) saved(ra, offset) else null) else null;
        const in_b = if (b) |rb| (if (offset < rb.len) saved(rb, offset) else null) else null;
        const page_base = base +% offset;
        if (in_a == null and in_b == null and mask.zeroPageClean(page_base, size) and peer.zeroPageClean(page_base, size)) continue;
        for (0..size) |i| {
            const addr = page_base +% @as(u32, @intCast(i));
            const raw_a: u8 = if (in_a) |bytes| bytes[i] else 0;
            const raw_b: u8 = if (in_b) |bytes| bytes[i] else 0;
            if (!mask.cell(addr, raw_a).eql(peer.cell(addr, raw_b))) {
                return .{ .address = addr, .expected = raw_a, .actual = raw_b };
            }
        }
    }
    return null;
}

/// Lowest address where `expected` (under `mask`) and `actual` (under
/// `mask.flipped()`) differ, or null when they digest alike.
pub fn firstDifference(expected: Parsed, actual: Parsed, mask: Mask) ?Spot {
    const sa = sortedRegions(expected);
    const sb = sortedRegions(actual);
    var ia: usize = 0;
    var ib: usize = 0;
    while (ia < sa.len or ib < sb.len) {
        const take_a = ia < sa.len and (ib >= sb.len or sa.items[ia].base <= sb.items[ib].base);
        const take_b = ib < sb.len and (ia >= sa.len or sb.items[ib].base <= sa.items[ia].base);
        if (take_a and take_b) {
            const a = sa.items[ia];
            const b = sb.items[ib];
            ia += 1;
            ib += 1;
            if (a.len != b.len) return .{ .address = a.base, .expected = 0, .actual = 0 };
            if (diffRegions(a, b, mask)) |spot| return spot;
        } else if (take_a) {
            const a = sa.items[ia];
            ia += 1;
            if (!mask.isOwnExtraWindow(a.base, a.len)) return .{ .address = a.base, .expected = 0, .actual = 0 };
            if (diffRegions(a, null, mask)) |spot| return spot;
        } else {
            const b = sb.items[ib];
            ib += 1;
            if (!mask.isOwnExtraWindow(b.base, b.len)) return .{ .address = b.base, .expected = 0, .actual = 0 };
            if (diffRegions(null, b, mask)) |spot| return spot;
        }
    }
    return null;
}

/// Feeds `parsed` into `hasher` under `mask`. `expected` under `mask` and
/// `actual` under `mask.flipped()` digest alike iff `firstDifference` is null.
pub fn hash(hasher: *std.crypto.hash.Blake3, parsed: Parsed, mask: Mask) void {
    const sorted = sortedRegions(parsed);
    for (sorted.items[0..sorted.len]) |region| {
        if (mask.isOwnExtraWindow(region.base, region.len)) continue;
        hasher.update(std.mem.asBytes(&std.mem.nativeToLittle(u32, region.base)));
        hasher.update(std.mem.asBytes(&std.mem.nativeToLittle(u32, region.len)));
    }
    hasher.update(&[_]u8{0xFF});
    var flags: [page / 8]u8 = undefined;
    var bytes: [page]u8 = undefined;
    for (sorted.items[0..sorted.len]) |region| {
        var offset: u32 = 0;
        while (offset < region.len) : (offset += page) {
            const size: u32 = @min(page, region.len - offset);
            const page_base = region.base +% offset;
            const in_page = saved(region, offset);
            if (in_page == null and mask.zeroPageClean(page_base, size)) continue;
            const flag_len: usize = (size + 7) / 8;
            @memset(flags[0..flag_len], 0);
            var any = false;
            for (0..size) |i| {
                const raw: u8 = if (in_page) |p| p[i] else 0;
                const c = mask.cell(page_base +% @as(u32, @intCast(i)), raw);
                bytes[i] = c.byte;
                if (c.mutated) flags[i / 8] |= @as(u8, 1) << @intCast(i % 8);
                any = any or c.mutated or c.byte != 0;
            }
            if (!any) continue;
            hasher.update(std.mem.asBytes(&std.mem.nativeToLittle(u32, page_base)));
            hasher.update(std.mem.asBytes(&std.mem.nativeToLittle(u32, size)));
            hasher.update(flags[0..flag_len]);
            hasher.update(bytes[0..size]);
        }
    }
    hasher.update(parsed.tail);
}
