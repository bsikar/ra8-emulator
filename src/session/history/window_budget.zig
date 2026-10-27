//! RAM budget scaling table and window sizing calculations (Section 2.9).
//!
//! The reverse window capacity scales with configured `ram_budget`:
//! - 1 GiB -> 64 MiB window
//! - 512 MiB -> 32 MiB window
//! - 256 MiB -> 16 MiB window
//! - 128 MiB -> 16 MiB window (floor)
//!
//! The `--ram-budget` command-line option has a hard floor of 128 MiB.
//! Default ram_budget is clamp(physical RAM / 8, 256 MiB, 1 GiB).
const std = @import("std");

pub const min_ram_budget: usize = 128 * 1024 * 1024;
pub const default_ram_budget_min: usize = 256 * 1024 * 1024;
pub const default_ram_budget_max: usize = 1024 * 1024 * 1024;

pub const min_window_bytes: usize = 16 * 1024 * 1024;
pub const default_window_bytes: usize = 64 * 1024 * 1024;

pub const BudgetTier = struct {
    ram_budget: usize,
    window_bytes: usize,
    hot_frames_bytes: usize,
    hot_checkpoints_bytes: usize,
    output_bytes: usize,
    workers_allowed: u8,
};

/// Computes the default ram_budget from host physical RAM.
pub fn defaultRamBudget(physical_ram: u64) usize {
    const eighth = physical_ram / 8;
    if (eighth < default_ram_budget_min) return default_ram_budget_min;
    if (eighth > default_ram_budget_max) return default_ram_budget_max;
    return @intCast(eighth);
}

/// Clamps a user-specified ram_budget to the hard floor of 128 MiB.
pub fn clampRamBudget(requested_budget: usize) usize {
    return @max(min_ram_budget, requested_budget);
}

/// Derives the reverse window capacity in bytes from the configured RAM budget.
pub fn windowCapacity(ram_budget: usize) usize {
    const budget = clampRamBudget(ram_budget);
    if (budget >= 1024 * 1024 * 1024) return 64 * 1024 * 1024;
    if (budget >= 512 * 1024 * 1024) return 32 * 1024 * 1024;
    return min_window_bytes;
}

/// Resolves the full budget tier breakdown for the given RAM budget.
pub fn tierFor(ram_budget: usize) BudgetTier {
    const budget = clampRamBudget(ram_budget);
    if (budget >= 1024 * 1024 * 1024) {
        return .{
            .ram_budget = budget,
            .window_bytes = 64 * 1024 * 1024,
            .hot_frames_bytes = 256 * 1024 * 1024,
            .hot_checkpoints_bytes = 640 * 1024 * 1024,
            .output_bytes = 64 * 1024 * 1024,
            .workers_allowed = 4,
        };
    } else if (budget >= 512 * 1024 * 1024) {
        return .{
            .ram_budget = budget,
            .window_bytes = 32 * 1024 * 1024,
            .hot_frames_bytes = 128 * 1024 * 1024,
            .hot_checkpoints_bytes = 320 * 1024 * 1024,
            .output_bytes = 32 * 1024 * 1024,
            .workers_allowed = 1,
        };
    } else if (budget >= 256 * 1024 * 1024) {
        return .{
            .ram_budget = budget,
            .window_bytes = 16 * 1024 * 1024,
            .hot_frames_bytes = 48 * 1024 * 1024,
            .hot_checkpoints_bytes = 160 * 1024 * 1024,
            .output_bytes = 32 * 1024 * 1024,
            .workers_allowed = 0,
        };
    } else {
        return .{
            .ram_budget = budget,
            .window_bytes = 16 * 1024 * 1024,
            .hot_frames_bytes = 0,
            .hot_checkpoints_bytes = 80 * 1024 * 1024,
            .output_bytes = 32 * 1024 * 1024,
            .workers_allowed = 0,
        };
    }
}
