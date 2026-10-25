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

const replay_mod = @import("replay.zig");

/// Raises each branch's recorded end to the newest record its own segment
/// holds. branches.bin is rewritten on structural changes only, so the
/// ends it carries can trail the log; the log's canonical positions are
/// where the ends are recovered from.
pub fn raiseEnds(graph: *branch_mod.BranchGraph, log_bytes: []const u8) !void {
    _ = try replay_mod.replay(log_bytes, graph, raiseOne);
}

fn raiseOne(graph: *branch_mod.BranchGraph, entry: replay_mod.Entry) anyerror!void {
    const at = switch (entry) {
        .root => return,
        inline else => |hit| hit.header.position,
    };
    const node = graph.nodes.getPtr(at.branch) orelse return;
    if (branch_mod.scalarOrder(at, node.recorded_end) == .gt) node.recorded_end = at;
}

/// The frames of a committed log stream, decoded up to its torn tail; the
/// payloads borrow `log_bytes`.
pub fn framesOf(allocator: std.mem.Allocator, log_bytes: []const u8) ![]history_format.Frame {
    var frames: std.ArrayList(history_format.Frame) = .empty;
    errdefer frames.deinit(allocator);
    var at: usize = 0;
    while (at < log_bytes.len) {
        const hit = history_format.decode(log_bytes[at..]) catch |err| switch (err) {
            error.Truncated => break,
            else => return err,
        };
        try frames.append(allocator, hit.frame);
        at += hit.consumed;
    }
    return frames.toOwnedSlice(allocator);
}

/// Recovery over branches.bin's two candidates with the log as the last
/// source: a graph rebuilt from the log's Branch records when neither file
/// decodes, and every branch's recorded end raised from the log.
pub fn recoverWithLog(
    allocator: std.mem.Allocator,
    current_bytes: ?[]const u8,
    temp_bytes: ?[]const u8,
    log_bytes: []const u8,
) !RecoveryResult {
    const frames = try framesOf(allocator, log_bytes);
    defer allocator.free(frames);
    var result = try recover(allocator, current_bytes, temp_bytes, frames);
    errdefer result.graph.deinit();
    try raiseEnds(&result.graph, log_bytes);
    return result;
}
