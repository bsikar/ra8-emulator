//! Wire types for branch RPC methods (Slice 20.4).
const std = @import("std");

pub const BranchItem = extern struct {
    id: u32,
    parent: u32,
    fork_r: u64,
    recorded_end_r: u64,
    child_count: u32,
    reason: u8,
    flags: u8,
    pad: u16 = 0,
};

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
