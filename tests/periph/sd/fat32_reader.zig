//! A small FAT32 reader for tests: parses the boot sector, follows FAT
//! chains and lists directories (long names included) over any source with
//! `read(lba, *[512]u8) bool`, such as the SDHI card.
const std = @import("std");

pub const Item = struct {
    name: []u8,
    is_dir: bool,
    cluster: u32,
    size: u32,
};

pub fn Reader(comptime Source: type) type {
    return struct {
        const Self = @This();
        source: Source,
        spc: u32,
        reserved: u32,
        fats: u32,
        fat_sectors: u32,
        root: u32,

        pub fn open(source: Source) !Self {
            var boot: [512]u8 = undefined;
            if (!source.read(0, &boot)) return error.ReadFailed;
            if (boot[510] != 0x55 or boot[511] != 0xAA) return error.NotFat;
            return .{
                .source = source,
                .spc = boot[13],
                .reserved = std.mem.readInt(u16, boot[14..16], .little),
                .fats = boot[16],
                .fat_sectors = std.mem.readInt(u32, boot[36..40], .little),
                .root = std.mem.readInt(u32, boot[44..48], .little),
            };
        }

        fn sectorOf(self: *const Self, cluster: u32) u32 {
            return self.reserved + self.fats * self.fat_sectors + (cluster - 2) * self.spc;
        }

        fn next(self: *const Self, cluster: u32) !u32 {
            var block: [512]u8 = undefined;
            const at = cluster * 4;
            if (!self.source.read(self.reserved + at / 512, &block)) return error.ReadFailed;
            return std.mem.readInt(u32, block[at % 512 ..][0..4], .little) & 0x0FFF_FFFF;
        }

        /// The whole chain from `first`, cut to `limit` bytes when given.
        pub fn chain(self: *const Self, allocator: std.mem.Allocator, first: u32, limit: ?u32) ![]u8 {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(allocator);
            var cluster = first;
            while (cluster >= 2 and cluster < 0x0FFF_FFF8) : (cluster = try self.next(cluster)) {
                var s: u32 = 0;
                while (s < self.spc) : (s += 1) {
                    var block: [512]u8 = undefined;
                    if (!self.source.read(self.sectorOf(cluster) + s, &block)) return error.ReadFailed;
                    try out.appendSlice(allocator, &block);
                }
                if (limit) |l| if (out.items.len >= l) break;
            }
            if (limit) |l| {
                if (out.items.len < l) return error.ShortChain;
                out.shrinkRetainingCapacity(l);
            }
            return out.toOwnedSlice(allocator);
        }
    };
}

/// The directory at `cluster`, without the label and the dot pair.
pub fn list(self: anytype, allocator: std.mem.Allocator, cluster: u32) ![]Item {
    const raw = try self.chain(allocator, cluster, null);
    defer allocator.free(raw);
    var items: std.ArrayList(Item) = .empty;
    var units: [260]u16 = undefined;
    var long_len: usize = 0;
    var at: usize = 0;
    while (at + 32 <= raw.len) : (at += 32) {
        const e = raw[at..][0..32];
        if (e[0] == 0) break;
        if (e[11] == 0x0F) {
            const chunk: usize = (e[0] & 0x3F) - 1;
            if (e[0] & 0x40 != 0) long_len = (chunk + 1) * 13;
            for (0..13) |k| {
                const off: usize = if (k < 5) 1 + 2 * k else if (k < 11) 14 + 2 * (k - 5) else 28 + 2 * (k - 11);
                units[chunk * 13 + k] = std.mem.readInt(u16, e[off..][0..2], .little);
            }
            continue;
        }
        defer long_len = 0;
        if (e[11] & 0x08 != 0 or e[0] == '.') continue;
        const name = if (long_len > 0) try longName(allocator, units[0..long_len]) else try shortName(allocator, e[0..11]);
        const hi: u32 = std.mem.readInt(u16, e[20..22], .little);
        try items.append(allocator, .{
            .name = name,
            .is_dir = e[11] & 0x10 != 0,
            .cluster = (hi << 16) | std.mem.readInt(u16, e[26..28], .little),
            .size = std.mem.readInt(u32, e[28..32], .little),
        });
    }
    return items.toOwnedSlice(allocator);
}

pub fn freeItems(allocator: std.mem.Allocator, items: []Item) void {
    for (items) |item| allocator.free(item.name);
    allocator.free(items);
}

fn longName(allocator: std.mem.Allocator, units: []const u16) ![]u8 {
    const end = std.mem.indexOfScalar(u16, units, 0) orelse units.len;
    return std.unicode.utf16LeToUtf8Alloc(allocator, units[0..end]);
}

fn shortName(allocator: std.mem.Allocator, raw: *const [11]u8) ![]u8 {
    const base = std.mem.trimEnd(u8, raw[0..8], " ");
    const ext = std.mem.trimEnd(u8, raw[8..11], " ");
    if (ext.len == 0) return allocator.dupe(u8, base);
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ base, ext });
}
