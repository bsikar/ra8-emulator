//! A sparse card's written blocks in a snapshot (RA8EMU-664).
//!
//! Both SD models keep only the blocks something wrote, as a map from block
//! number to a heap block. The map holds pointers and an allocator, so it
//! goes as a count and then each block number with its 512 bytes, numbers
//! ascending so the same card always writes the same bytes.
const std = @import("std");
const fields = @import("fields.zig");

pub const block_bytes = 512;
pub const Block = [block_bytes]u8;
pub const Map = std.AutoHashMap(u32, *Block);

const entry_bytes = 4 + block_bytes;

pub fn write(writer: anytype, map: *const Map) !void {
    const keys = try map.allocator.alloc(u32, map.count());
    defer map.allocator.free(keys);
    var it = map.keyIterator();
    for (keys) |*key| key.* = it.next().?.*;
    std.mem.sort(u32, keys, {}, std.sort.asc(u32));
    try fields.write(writer, @as(u32, @intCast(keys.len)));
    for (keys) |key| {
        try fields.write(writer, key);
        try writer.writeAll(map.get(key).?);
    }
}

/// The blocks of one card as they sit in the payload, already checked:
/// every number below `capacity` and strictly ascending.
pub const List = struct {
    bytes: []const u8,
    count: u32,

    pub fn read(cursor: *fields.Cursor, capacity: u32) fields.Error!List {
        const count = try fields.read(u32, cursor);
        const len = @as(usize, count) * entry_bytes;
        if (len > cursor.bytes.len - cursor.at) return error.Truncated;
        const list: List = .{ .bytes = cursor.bytes[cursor.at..][0..len], .count = count };
        cursor.at += len;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const index = list.number(i);
            if (index >= capacity or (i > 0 and index <= list.number(i - 1))) return error.BadValue;
        }
        return list;
    }

    fn number(self: List, i: u32) u32 {
        return std.mem.readInt(u32, self.bytes[@as(usize, i) * entry_bytes ..][0..4], .little);
    }

    /// A fresh map holding these blocks; on failure nothing is left allocated.
    pub fn build(self: List, allocator: std.mem.Allocator) error{OutOfMemory}!Map {
        var map = Map.init(allocator);
        errdefer free(&map);
        try map.ensureTotalCapacity(self.count);
        var i: u32 = 0;
        while (i < self.count) : (i += 1) {
            const block = try allocator.create(Block);
            block.* = self.bytes[@as(usize, i) * entry_bytes + 4 ..][0..block_bytes].*;
            map.putAssumeCapacity(self.number(i), block);
        }
        return map;
    }
};

pub fn free(map: *Map) void {
    var it = map.valueIterator();
    while (it.next()) |block| map.allocator.destroy(block.*);
    map.deinit();
}
