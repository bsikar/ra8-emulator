//! Pure session-layer recovery decision over candidate branches.bin buffers.
//!
//! A temporary file that decodes cleanly represents the newest completed commit
//! (written and synced before the atomic rename was attempted), so it is preferred
//! over the current file regardless of branch counts. If the temporary file is
//! missing or invalid, the current file is adopted if valid. If neither decodes,
//! recovery yields a graph rebuilt from log branch records or the base line.
const std = @import("std");
const branch_mod = @import("branch.zig");
const codec = @import("branches_codec.zig");
const history_format = @import("format.zig");

pub const Action = enum {
    use_temp,
    use_current,
    use_base,
};

pub const RecoveryResult = struct {
    graph: branch_mod.BranchGraph,
    action: Action,
};

/// Pure recovery decision selecting between current bytes, temp bytes, and log frames.
pub fn recover(
    allocator: std.mem.Allocator,
    current_bytes: ?[]const u8,
    temp_bytes: ?[]const u8,
    log_frames: ?[]const history_format.Frame,
) !RecoveryResult {
    // 1. A temporary file that decodes cleanly is the newest completed commit.
    if (temp_bytes) |tb| {
        if (codec.decode(allocator, tb)) |graph| {
            return RecoveryResult{
                .graph = graph,
                .action = .use_temp,
            };
        } else |_| {}
    }

    // 2. Temp was absent or invalid. Adopt current file if it decodes cleanly.
    if (current_bytes) |cb| {
        if (codec.decode(allocator, cb)) |graph| {
            return RecoveryResult{
                .graph = graph,
                .action = .use_current,
            };
        } else |_| {}
    }

    // 3. Neither decodes. Fall back to event log reconstruction if frames are provided.
    if (log_frames) |frames| {
        if (frames.len > 0) {
            const graph = try codec.rebuildFromLogFrames(allocator, frames);
            return RecoveryResult{
                .graph = graph,
                .action = .use_base,
            };
        }
    }

    // 4. Default to base line only.
    const base_graph = try branch_mod.BranchGraph.init(allocator);
    return RecoveryResult{
        .graph = base_graph,
        .action = .use_base,
    };
}
