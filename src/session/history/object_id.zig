//! 128-bit content-addressed object identity using truncated Blake3, with
//! XxHash3-64 prefiltering for index lookups.
//!
//! Blake3 provides cryptographic collision resistance. The first 128 bits
//! form the persistent object identifier. XxHash3-64 provides high-throughput
//! index prefiltering, but an equal prefilter NEVER implies equal identity;
//! full 128-bit comparison is always performed to guard against collisions.
const std = @import("std");

pub const ObjectId = struct {
    bytes: [16]u8,

    pub const len: usize = 16;
    pub const hex_len: usize = 32;
    pub const zero: ObjectId = .{ .bytes = @splat(0) };

    /// Computes the 128-bit Blake3 digest over `data`.
    pub fn compute(data: []const u8) ObjectId {
        var full: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(data, &full, .{});
        return .{ .bytes = full[0..len].* };
    }

    /// High-throughput 64-bit prefilter derived via XxHash3 over object bytes.
    /// Used for fast index rejection. Equal prefilter does NOT imply equality.
    pub fn prefilter(self: ObjectId) u64 {
        return std.hash.XxHash3.hash(0, &self.bytes);
    }

    /// Full 128-bit cryptographic equality comparison.
    pub fn eql(self: ObjectId, other: ObjectId) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }

    /// Total ordering for binary search and canonical sorting.
    pub fn order(self: ObjectId, other: ObjectId) std.math.Order {
        return std.mem.order(u8, &self.bytes, &other.bytes);
    }

    /// Formats the 16 bytes into a 32-character lowercase hex string.
    pub fn formatHex(self: ObjectId, out: *[hex_len]u8) void {
        const hex_digits = "0123456789abcdef";
        for (self.bytes, 0..) |b, i| {
            out[i * 2] = hex_digits[b >> 4];
            out[i * 2 + 1] = hex_digits[b & 0x0f];
        }
    }

    /// Parses a 32-character hex string into an ObjectId.
    pub fn fromHex(hex: []const u8) error{BadHex}!ObjectId {
        if (hex.len != hex_len) return error.BadHex;
        var bytes: [len]u8 = undefined;
        for (0..len) |i| {
            const hi = try hexNibble(hex[i * 2]);
            const lo = try hexNibble(hex[i * 2 + 1]);
            bytes[i] = (hi << 4) | lo;
        }
        return .{ .bytes = bytes };
    }

    fn hexNibble(c: u8) error{BadHex}!u8 {
        return switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => error.BadHex,
        };
    }
};
