//! Wire types for branch RPC methods (Slice 20.4).
const std = @import("std");

/// One branch as the list carries it. On the wire each item is `item_bytes`
/// little-endian bytes written by `put` and read back by `get`, so neither
/// side ever reinterprets an unaligned byte buffer as a struct.
pub const BranchItem = struct {
    id: u32,
    parent: u32,
    fork_r: u64,
    recorded_end_r: u64,
    child_count: u32,
    /// The record.ForkReason value the branch forked for.
    reason: u8,
    /// Bit 0 live, bit 1 kept, bit 2 pinned.
    flags: u8,
};

/// The bytes one encoded BranchItem occupies.
pub const item_bytes: usize = 4 + 4 + 8 + 8 + 4 + 1 + 1;

/// The most items one BranchList carries.
pub const max_items: usize = BranchList.max_len.bytes / item_bytes;

/// Writes `item` at slot `index` of `bytes`.
pub fn put(bytes: []u8, index: usize, item: BranchItem) void {
    const at = bytes[index * item_bytes ..][0..item_bytes];
    std.mem.writeInt(u32, at[0..4], item.id, .little);
    std.mem.writeInt(u32, at[4..8], item.parent, .little);
    std.mem.writeInt(u64, at[8..16], item.fork_r, .little);
    std.mem.writeInt(u64, at[16..24], item.recorded_end_r, .little);
    std.mem.writeInt(u32, at[24..28], item.child_count, .little);
    at[28] = item.reason;
    at[29] = item.flags;
}

/// How many whole items `bytes` holds.
pub fn count(bytes: []const u8) usize {
    return bytes.len / item_bytes;
}

/// Reads the item at slot `index` of `bytes`.
pub fn get(bytes: []const u8, index: usize) BranchItem {
    const at = bytes[index * item_bytes ..][0..item_bytes];
    return .{
        .id = std.mem.readInt(u32, at[0..4], .little),
        .parent = std.mem.readInt(u32, at[4..8], .little),
        .fork_r = std.mem.readInt(u64, at[8..16], .little),
        .recorded_end_r = std.mem.readInt(u64, at[16..24], .little),
        .child_count = std.mem.readInt(u32, at[24..28], .little),
        .reason = at[28],
        .flags = at[29],
    };
}

/// The branch list: `count` items, `item_bytes` each, in `bytes`.
pub const BranchList = struct {
    count: u32,
    bytes: []const u8,
    pub const max_len = .{ .bytes = 65536 };
};

pub const BranchSwitch = struct {
    branch: u32,
};

pub const BranchDelete = struct {
    branch: u32,
    confirm: u8 = 0,
};

pub const BranchConfirmFork = struct {
    confirm: u8 = 1,
};

pub const BranchCancelFork = struct {};

pub const ForkStatus = struct {
    pending: u8,
    reason: u8,
    branch: u32,
    r: u64,
};
