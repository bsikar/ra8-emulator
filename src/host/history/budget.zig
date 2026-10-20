//! Pure byte budgets. The machine allocation is outside these shares.
const std = @import("std");

pub const bytes = struct {
    pub const mib: u64 = 1024 * 1024;
    pub const gib: u64 = 1024 * mib;
    pub const floor: u64 = 128 * mib;
    pub const window_floor: u64 = 16 * mib;
};

pub const Shares = struct {
    window: u64,
    frames: u64,
    checkpoints: u64,
    output: u64,
    workers: u32,

    pub fn total(self: Shares) u64 {
        return self.window + self.frames + self.checkpoints + self.output;
    }
};

pub fn defaultRam(physical: u64) u64 {
    return std.math.clamp(physical / 8, 256 * bytes.mib, bytes.gib);
}

pub fn ram(physical: u64, override: ?u64) error{BudgetTooSmall}!u64 {
    const result = override orelse defaultRam(physical);
    if (result < bytes.floor) return error.BudgetTooSmall;
    return result;
}

/// Start at the next tier up, then shrink checkpoints, frames and window.
/// The explicit override is a cap, including for values between tiers.
pub fn partition(cap: u64) error{BudgetTooSmall}!Shares {
    if (cap < bytes.floor) return error.BudgetTooSmall;
    var result: Shares = if (cap > 512 * bytes.mib)
        .{ .window = 64 * bytes.mib, .frames = 256 * bytes.mib, .checkpoints = 640 * bytes.mib, .output = 64 * bytes.mib, .workers = if (cap >= bytes.gib) 4 else 1 }
    else if (cap > 256 * bytes.mib)
        .{ .window = 32 * bytes.mib, .frames = 128 * bytes.mib, .checkpoints = 320 * bytes.mib, .output = 32 * bytes.mib, .workers = if (cap >= 512 * bytes.mib) 1 else 0 }
    else if (cap > bytes.floor)
        .{ .window = 16 * bytes.mib, .frames = 48 * bytes.mib, .checkpoints = 160 * bytes.mib, .output = 32 * bytes.mib, .workers = 0 }
    else
        .{ .window = 16 * bytes.mib, .frames = 0, .checkpoints = 80 * bytes.mib, .output = 32 * bytes.mib, .workers = 0 };
    var excess = result.total() -| cap;
    shrink(&result.checkpoints, 80 * bytes.mib, &excess);
    shrink(&result.frames, 0, &excess);
    shrink(&result.window, bytes.window_floor, &excess);
    return result;
}

fn shrink(share: *u64, floor: u64, excess: *u64) void {
    const cut = @min(share.* - floor, excess.*);
    share.* -= cut;
    excess.* -= cut;
}

pub const Disk = struct {
    ephemeral: u64,
    kept: u64,
    session: u64,
    frames: u64,
    checkpoints: u64,
    free_floor: u64,
};

/// Session minimums can overcommit the global cap. Both global and local
/// caps must be checked at commit; one cannot replace the other.
pub fn disk(volume: u64, live: u64) Disk {
    const ephemeral = @min(10 * bytes.gib, volume / 10);
    const share = @max(bytes.gib, ephemeral / @max(1, live));
    return .{
        .ephemeral = ephemeral,
        .kept = @min(20 * bytes.gib, volume / 10),
        .session = share,
        .frames = share / 5,
        .checkpoints = percent(share, 60),
        .free_floor = @max(2 * bytes.gib, volume / 20),
    };
}

pub const Relief = enum { orphans, frames, checkpoints, stop };
pub const relief_order = [_]Relief{ .orphans, .frames, .checkpoints, .stop };

fn percent(value: u64, part: u64) u64 {
    return @intCast(@as(u128, value) * part / 100);
}
