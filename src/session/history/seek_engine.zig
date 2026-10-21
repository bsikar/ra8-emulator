//! The seek engine's base selection (unit 17): from one typed target, the
//! cheapest place a replay starts from.
//!
//! The design's three candidates are the reverse window's redo/undo base
//! (unit 21), the live cursor's state, and the nearest checkpoint at or
//! before the target on the line. This file plans from the two that exist:
//! the window is not a candidate yet, so a backward seek with no checkpoint
//! at or before the target is a pending outcome naming exactly that, never
//! a plan from something that does not exist. The same honesty covers the
//! target kinds whose resolution needs an index that has not landed: a
//! pending outcome names the missing index, and nothing is invented.
//!
//! Cost is the replay's round distance, the span a replay actually runs;
//! when the live state and the best checkpoint tie, the live state wins,
//! because it needs no object loaded and no digest checked.

const std = @import("std");
const seek_target = @import("seek_target.zig");
const position_mod = @import("position.zig");

pub const Position = position_mod.Position;

/// One checkpoint the committed log names, as the base-selection index
/// reads it: where it sits on its line, which checkpoint id it carries,
/// and which saved object pins its state (the record body's raw 16 bytes;
/// the object space files carry those as their 32-hex name).
pub const Checkpoint = struct {
    position: Position,
    id: u32,
    object: [16]u8,
};

/// What the caller holds about the live run: the cursor's position and
/// every checkpoint the committed log names, any order.
pub const Facts = struct {
    current: Position,
    checkpoints: []const Checkpoint,
};

/// A target this engine cannot plan yet, and why. The transport reports
/// the reason as the capability still to land.
pub const Pending = struct {
    what: []const u8,
};

/// The chosen base and what replaying it to the target costs.
pub const Plan = struct {
    base: Base,
    /// Rounds between the base and the target; zero when the base is
    /// already there.
    replay_rounds: u64,
};

pub const Base = union(enum) {
    /// The live cursor's state, replayed forward to the target.
    current,
    /// A checkpoint at or before the target, replayed forward from its
    /// saved object.
    checkpoint: struct {
        id: u32,
        object: [16]u8,
        position: Position,
    },
};

pub const Outcome = union(enum) {
    plan: Plan,
    pending: Pending,
};

/// Plans one seek. Only a position target plans today: it is the one kind
/// whose resolution the committed log and the cursor already prove. The
/// other kinds wait for the indexes their resolution needs and come back
/// pending, each naming its own missing piece.
pub fn plan(target: seek_target.Target, facts: Facts) Outcome {
    switch (target) {
        .position => |pt| return planPosition(pt.position, facts),
        .time => return .{ .pending = .{ .what = "the virtual-time index" } },
        .percent => return .{ .pending = .{ .what = "the virtual-time index" } },
        .frame => return .{ .pending = .{ .what = "the frame index" } },
        .iteration => return .{ .pending = .{ .what = "the round-boundary index" } },
        .bookmark => return .{ .pending = .{ .what = "bookmark storage" } },
        .point => return .{ .pending = .{ .what = "the arrival index" } },
    }
}

fn planPosition(target: Position, facts: Facts) Outcome {
    const order = position_mod.compare(target, facts.current) catch
        return .{ .pending = .{ .what = "another line's seek" } };
    if (order == .eq) return .{ .plan = .{ .base = .current, .replay_rounds = 0 } };
    const best = nearestAtOrBefore(target, facts.checkpoints);
    if (order == .gt) {
        // Forward: the live cursor is a candidate too, and the tie goes
        // to it. With no checkpoint the cursor is the only base.
        const live_rounds = target.r - facts.current.r;
        if (best == null or live_rounds <= target.r - best.?.position.r)
            return .{ .plan = .{ .base = .current, .replay_rounds = live_rounds } };
        return checkpointPlan(best.?, target);
    }
    // Backward: the cursor cannot go back, so the plan replays forward
    // from a checkpoint; with none, the only base is the reverse
    // window's undo, which is still to land.
    const chosen = best orelse return .{ .pending = .{ .what = "the reverse window's undo base" } };
    return checkpointPlan(chosen, target);
}

fn checkpointPlan(chosen: Checkpoint, target: Position) Outcome {
    return .{ .plan = .{
        .base = .{ .checkpoint = .{
            .id = chosen.id,
            .object = chosen.object,
            .position = chosen.position,
        } },
        .replay_rounds = target.r - chosen.position.r,
    } };
}

/// The nearest checkpoint at or before the target on the target's line.
/// Checkpoints on another line are skipped, not errors: the base index
/// holds every line's checkpoints, and a seek plans only its own.
fn nearestAtOrBefore(target: Position, checkpoints: []const Checkpoint) ?Checkpoint {
    var best: ?Checkpoint = null;
    for (checkpoints) |c| {
        const before = position_mod.compare(c.position, target) catch continue;
        if (before == .gt) continue;
        const better = best == null or c.position.r > best.?.position.r;
        if (better) best = c;
    }
    return best;
}
