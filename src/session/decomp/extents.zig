//! Function extent discovery and symbol resolution seeded from ELF symbols (RA8EMU-1353).
const std = @import("std");

const annotate = @import("../annotate.zig");
const elf = @import("ra8_board").image.elf;
const symbols = @import("../symbols.zig");

/// Normalized Thumb entry address, byte extent, and optional canonical symbol name.
pub const FunctionExtent = struct {
    entry: u32,
    size: u32,
    name: ?[]const u8 = null,
};

/// Resolved call or branch target summary through the symbol layer.
pub const TargetSymbol = struct {
    address: u32,
    entry: u32,
    name: ?[]const u8 = null,
};

/// Collect sorted, address-deduplicated function extents from `image` using
/// `symbols.functionExtents`, attaching canonical names from the symbol table.
/// Returned `.name` slices point into `image.bytes`.
pub fn collect(allocator: std.mem.Allocator, image: elf.Image) std.mem.Allocator.Error![]FunctionExtent {
    const sym_total = symbols.count(image);
    if (sym_total == 0) return allocator.alloc(FunctionExtent, 0);

    const raw = try allocator.alloc(symbols.Extent, sym_total);
    defer allocator.free(raw);

    const filled = symbols.functionExtents(image, raw);
    if (filled == 0) return allocator.alloc(FunctionExtent, 0);

    std.mem.sort(symbols.Extent, raw[0..filled], {}, rawLessThan);

    var out: std.ArrayListUnmanaged(FunctionExtent) = .empty;
    errdefer out.deinit(allocator);

    for (raw[0..filled]) |item| {
        const entry = item.address & ~@as(u32, 1);
        if (out.items.len > 0 and out.items[out.items.len - 1].entry == entry) continue;
        try out.append(allocator, .{ .entry = entry, .size = item.size });
    }

    attachNames(image, out.items);
    return out.toOwnedSlice(allocator);
}

/// Binary-search for a function extent whose exact normalized entry matches `address`.
pub fn findByEntry(list: []const FunctionExtent, address: u32) ?*const FunctionExtent {
    const norm = address & ~@as(u32, 1);
    var low: usize = 0;
    var high: usize = list.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (list[mid].entry < norm) {
            low = mid + 1;
        } else if (list[mid].entry > norm) {
            high = mid;
        } else {
            return &list[mid];
        }
    }
    return null;
}

/// Find the innermost function extent covering `address` (`entry <= norm < entry + size`).
pub fn findContaining(list: []const FunctionExtent, address: u32) ?*const FunctionExtent {
    const norm = address & ~@as(u32, 1);
    var low: usize = 0;
    var high: usize = list.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (list[mid].entry <= norm) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    var idx = low;
    while (idx > 0) {
        idx -= 1;
        const ext = &list[idx];
        const start: u64 = ext.entry;
        const end: u64 = start + ext.size;
        if (@as(u64, norm) < end) return ext;
    }
    return null;
}

/// Resolve an instruction target address through `list` and the ELF symbol table.
pub fn resolveTarget(image: ?elf.Image, list: []const FunctionExtent, address: u32) TargetSymbol {
    const norm = address & ~@as(u32, 1);
    if (findByEntry(list, norm)) |ext| {
        return .{ .address = norm, .entry = ext.entry, .name = ext.name };
    }
    if (image) |img| {
        if (annotate.symbolAt(img, norm)) |sym_name| {
            return .{ .address = norm, .entry = norm, .name = sym_name };
        }
        if (symbols.inside(img, norm)) |hit| {
            return .{ .address = norm, .entry = norm -% hit.offset, .name = hit.name };
        }
    }
    return .{ .address = norm, .entry = norm, .name = null };
}

fn rawLessThan(_: void, a: symbols.Extent, b: symbols.Extent) bool {
    const na = a.address & ~@as(u32, 1);
    const nb = b.address & ~@as(u32, 1);
    if (na != nb) return na < nb;
    return a.size > b.size;
}

fn attachNames(image: elf.Image, list: []FunctionExtent) void {
    var walk = symbols.Walk.init(image);
    while (walk.next()) |sym| {
        if (sym.kind != symbols.symbol_type.func) continue;
        if (isMappingSymbol(sym.name)) continue;
        const idx = findIndex(list, sym.value & ~@as(u32, 1)) orelse continue;
        if (list[idx].name == null) list[idx].name = sym.name;
    }
}

fn findIndex(list: []const FunctionExtent, norm: u32) ?usize {
    var low: usize = 0;
    var high: usize = list.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (list[mid].entry < norm) {
            low = mid + 1;
        } else if (list[mid].entry > norm) {
            high = mid;
        } else {
            return mid;
        }
    }
    return null;
}

fn isMappingSymbol(name: []const u8) bool {
    if (name.len < 2 or name[0] != '$') return false;
    return name[1] == 't' or name[1] == 'd' or name[1] == 'a';
}
