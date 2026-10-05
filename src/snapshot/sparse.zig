//! Sparse contents in a snapshot (RA8EMU-674): a count, then each entry's
//! u32 number and its fixed-size bytes, numbers strictly ascending so the
//! same contents always write the same bytes. The option MRAM's OTP cells
//! (one byte each) and the xSPI flash's sectors (4 KiB each) go this way.
const std = @import("std");
const fields = @import("fields.zig");

/// The numbers of a map's entries, ascending. Caller frees.
pub fn sortedKeys(allocator: std.mem.Allocator, map: anytype) ![]u32 {
    const keys = try allocator.alloc(u32, map.count());
    var it = map.keyIterator();
    for (keys) |*key| key.* = it.next().?.*;
    std.mem.sort(u32, keys, {}, std.sort.asc(u32));
    return keys;
}

pub fn writeCount(writer: anytype, keys: []const u32) !void {
    try fields.write(writer, @as(u32, @intCast(keys.len)));
}

/// Entries of `size` bytes as they sit in the payload, already checked:
/// every number accepted by `valid` and strictly ascending.
pub fn List(comptime size: usize) type {
    return struct {
        const Self = @This();
        const entry = 4 + size;

        bytes: []const u8,
        count: u32,

        pub fn read(cursor: *fields.Cursor, comptime valid: fn (u32) bool) fields.Error!Self {
            const count = try fields.read(u32, cursor);
            const len = @as(usize, count) * entry;
            if (len > cursor.bytes.len - cursor.at) return error.Truncated;
            const list: Self = .{ .bytes = cursor.bytes[cursor.at..][0..len], .count = count };
            cursor.at += len;
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                const n = list.number(i);
                if (!valid(n) or (i > 0 and n <= list.number(i - 1))) return error.BadValue;
            }
            return list;
        }

        pub fn number(self: Self, i: u32) u32 {
            return std.mem.readInt(u32, self.bytes[@as(usize, i) * entry ..][0..4], .little);
        }

        pub fn value(self: Self, i: u32) *const [size]u8 {
            return self.bytes[@as(usize, i) * entry + 4 ..][0..size];
        }
    };
}
