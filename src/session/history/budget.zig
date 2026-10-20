//! The persistent history's disk-side enforcement, applied where the bytes
//! go out: a commit or a checkpoint may only land when the volume still
//! holds this history's share. The application computes the shares and
//! reads the free space (src/host/history/budget.zig, resources.zig);
//! this file answers whether the bytes may go out. Session stays
//! std-only, so the enforcement math lives here and never touches the
//! host.
const std = @import("std");

pub const Pressure = enum { normal, warning, history_full };

pub fn pressure(used: u64, cap: u64) Pressure {
    if (used >= cap) return .history_full;
    return if (@as(u128, used) * 100 >= @as(u128, cap) * 80) .warning else .normal;
}

/// Checked before each commit and checkpoint with fresh free-space
/// information the application read for the moment.
pub fn checkCommit(used: u64, additional: u64, cap: u64, free: u64, floor: u64) error{HistoryFull}!Pressure {
    if (additional > free or free - additional < floor or additional > cap or used >= cap - additional) return error.HistoryFull;
    return pressure(used + additional, cap);
}
