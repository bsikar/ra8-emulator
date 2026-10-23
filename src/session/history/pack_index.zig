//! Pure index layout and lookup for pack files, with sorted binary search
//! and XxHash3-64 prefilter check. Equal prefilter never implies equal identity.
//! Also provides crash recovery index rebuilding from raw pack bytes.
const std = @import("std");
const ObjectId = @import("object_id.zig").ObjectId;
const pack_mod = @import("pack.zig");
const Crc32c = std.hash.crc.@"CRC-32/ISCSI";

pub const magic: [8]u8 = "RA8PIDX1".*;
pub const trailer_magic: [4]u8 = "EDPX".*;
pub const version: u32 = 1;
pub const header_len: usize = 32;
pub const entry_len: usize = 40;
pub const trailer_len: usize = 8;

pub const Error = error{
    BadMagic,
    BadVersion,
    TruncatedIndex,
    BadCrc,
    NotSorted,
    CorruptPack,
    OutOfMemory,
};

pub const Entry = struct {
    object_id: ObjectId,
    xxh3_prefilter: u64,
    pack_offset: u64,
    compressed_len: u32,
    uncompressed_len: u32,

    pub fn order(context: void, a: Entry, b: Entry) bool {
        _ = context;
        return a.object_id.order(b.object_id) == .lt;
    }
};

pub const Index = struct {
    pack_id: u32,
    entries: []Entry,

    pub fn deinit(self: *Index, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        self.* = undefined;
    }

    /// Fast lookup by ObjectId using binary search.
    /// Fast prefilter check is evaluated, but full 128-bit comparison is mandatory.
    pub fn lookup(self: *const Index, id: ObjectId) ?Entry {
        const pref = id.prefilter();
        var low: usize = 0;
        var high: usize = self.entries.len;

        while (low < high) {
            const mid = low + (high - low) / 2;
            const entry = &self.entries[mid];
            const ord = id.order(entry.object_id);

            switch (ord) {
                .eq => {
                    // Full 128-bit matched. Verify prefilter consistency.
                    if (entry.xxh3_prefilter != pref) return null;
                    return entry.*;
                },
                .lt => high = mid,
                .gt => low = mid + 1,
            }
        }
        return null;
    }
};

/// Encodes index entries to writer, asserting or sorting them lexicographically.
pub fn encode(allocator: std.mem.Allocator, writer: anytype, pack_id: u32, entries: []const Entry) !void {
    const sorted = try allocator.dupe(Entry, entries);
    defer allocator.free(sorted);
    std.mem.sort(Entry, sorted, {}, Entry.order);

    var crc = Crc32c.init();

    var header_buf: [header_len]u8 = @splat(0);
    @memcpy(header_buf[0..8], &magic);
    std.mem.writeInt(u32, header_buf[8..12], version, .little);
    std.mem.writeInt(u32, header_buf[12..16], pack_id, .little);
    std.mem.writeInt(u32, header_buf[16..20], @intCast(sorted.len), .little);

    try writer.writeAll(&header_buf);
    crc.update(&header_buf);

    for (sorted) |entry| {
        var e_buf: [entry_len]u8 = undefined;
        @memcpy(e_buf[0..16], &entry.object_id.bytes);
        std.mem.writeInt(u64, e_buf[16..24], entry.xxh3_prefilter, .little);
        std.mem.writeInt(u64, e_buf[24..32], entry.pack_offset, .little);
        std.mem.writeInt(u32, e_buf[32..36], entry.compressed_len, .little);
        std.mem.writeInt(u32, e_buf[36..40], entry.uncompressed_len, .little);
        try writer.writeAll(&e_buf);
        crc.update(&e_buf);
    }

    var trailer_buf: [trailer_len]u8 = undefined;
    std.mem.writeInt(u32, trailer_buf[0..4], crc.final(), .little);
    @memcpy(trailer_buf[4..8], &trailer_magic);
    try writer.writeAll(&trailer_buf);
}

/// Decodes an index from bytes, validating magic, version, CRC and sorted order.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!Index {
    if (bytes.len < header_len + trailer_len) return Error.TruncatedIndex;

    if (!std.mem.eql(u8, bytes[0..8], &magic)) return Error.BadMagic;
    const v = std.mem.readInt(u32, bytes[8..12], .little);
    if (v != version) return Error.BadVersion;

    const pack_id = std.mem.readInt(u32, bytes[12..16], .little);
    const count = std.mem.readInt(u32, bytes[16..20], .little);

    const expected_total = header_len + @as(usize, count) * entry_len + trailer_len;
    if (bytes.len != expected_total) return Error.TruncatedIndex;

    var crc = Crc32c.init();
    crc.update(bytes[0 .. bytes.len - trailer_len]);
    const stored_crc = std.mem.readInt(u32, bytes[bytes.len - 8 ..][0..4], .little);
    if (crc.final() != stored_crc) return Error.BadCrc;
    if (!std.mem.eql(u8, bytes[bytes.len - 4 ..], &trailer_magic)) return Error.BadMagic;

    const entries = try allocator.alloc(Entry, count);
    errdefer allocator.free(entries);

    var at: usize = header_len;
    for (0..count) |i| {
        entries[i] = .{
            .object_id = ObjectId{ .bytes = bytes[at..][0..16].* },
            .xxh3_prefilter = std.mem.readInt(u64, bytes[at + 16 ..][0..8], .little),
            .pack_offset = std.mem.readInt(u64, bytes[at + 24 ..][0..8], .little),
            .compressed_len = std.mem.readInt(u32, bytes[at + 32 ..][0..4], .little),
            .uncompressed_len = std.mem.readInt(u32, bytes[at + 36 ..][0..4], .little),
        };
        if (i > 0) {
            if (entries[i - 1].object_id.order(entries[i].object_id) != .lt) {
                return Error.NotSorted;
            }
        }
        at += entry_len;
    }

    return .{
        .pack_id = pack_id,
        .entries = entries,
    };
}

/// Rebuilds a lost or missing index by sequentially scanning pack bytes.
pub fn rebuildFromPack(allocator: std.mem.Allocator, pack_bytes: []const u8) Error!Index {
    const pack_id = pack_mod.readHeader(pack_bytes) catch return Error.CorruptPack;

    var list: std.ArrayList(Entry) = .empty;
    defer list.deinit(allocator);

    var at: usize = pack_mod.header_len;
    while (at < pack_bytes.len) {
        if (at + pack_mod.record_overhead > pack_bytes.len) return Error.CorruptPack;

        const obj_id = ObjectId{ .bytes = pack_bytes[at..][0..16].* };
        const uncompressed_len = std.mem.readInt(u32, pack_bytes[at + 16 ..][0..4], .little);
        const compressed_len = std.mem.readInt(u32, pack_bytes[at + 20 ..][0..4], .little);

        const total_rec = pack_mod.record_overhead + @as(usize, compressed_len);
        if (at + total_rec > pack_bytes.len) return Error.CorruptPack;

        const payload = pack_bytes[at + pack_mod.record_header_len .. at + pack_mod.record_header_len + compressed_len];
        const stored_crc = std.mem.readInt(u32, pack_bytes[at + pack_mod.record_header_len + compressed_len ..][0..4], .little);

        var crc = Crc32c.init();
        crc.update(pack_bytes[at .. at + pack_mod.record_header_len]);
        crc.update(payload);
        if (crc.final() != stored_crc) return Error.CorruptPack;

        list.append(allocator, .{
            .object_id = obj_id,
            .xxh3_prefilter = obj_id.prefilter(),
            .pack_offset = at,
            .compressed_len = compressed_len,
            .uncompressed_len = uncompressed_len,
        }) catch return Error.OutOfMemory;

        at += total_rec;
    }

    const entries = list.toOwnedSlice(allocator) catch return Error.OutOfMemory;
    std.mem.sort(Entry, entries, {}, Entry.order);

    return .{
        .pack_id = pack_id,
        .entries = entries,
    };
}
