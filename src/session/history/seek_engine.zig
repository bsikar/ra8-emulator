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
const branch_mod = @import("branch.zig");
const cross_seek = @import("cross_seek.zig");

pub const Position = position_mod.Position;
pub const BranchGraph = branch_mod.BranchGraph;
pub const BranchId = branch_mod.BranchId;

/// One checkpoint the committed log names, as the base-selection index
/// reads it: where it sits on its line, which checkpoint id it carries,
/// and which saved object pins its state (the record body's raw 16 bytes;
/// the object space files carry those as their 32-hex name).
pub const Checkpoint = struct {
    position: Position,
    id: u32,
    object: [16]u8,
};

pub const WindowFacts = struct {
    start: Position,
    end: Position,
    at: Position,
    line: ?BranchId = null,
    slots: u64 = 0,
};

/// What the caller holds about the live run: the cursor's position and
/// every checkpoint the committed log names, any order.
pub const Facts = struct {
    current: Position,
    checkpoints: []const Checkpoint,
    graph: ?*const BranchGraph = null,
    active_line: BranchId = branch_mod.root_branch_id,
    window: ?WindowFacts = null,
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

pub const WindowDirection = enum { undo, redo };

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
    /// The reverse window's redo/undo base.
    window: struct {
        position: Position,
        dir: WindowDirection,
        slots: u64 = 0,
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

const WindowCover = struct {
    dir: WindowDirection,
    rounds: u64,
    slots: u64,
};

fn windowCovers(facts: Facts, target: Position) ?WindowCover {
    const win = facts.window orelse return null;
    if (facts.graph) |graph| {
        if (win.line) |wl| {
            if (wl != facts.active_line) return null;
        }
        const target_canon = graph.canonicalize(facts.active_line, target) catch return null;
        const win_start = graph.canonicalize(facts.active_line, win.start) catch return null;
        const win_end = graph.canonicalize(facts.active_line, win.end) catch return null;
        const win_at = graph.canonicalize(facts.active_line, win.at) catch return null;
        if (branch_mod.scalarOrder(target_canon, win_start) == .lt) return null;
        if (branch_mod.scalarOrder(target_canon, win_end) == .gt) return null;
        const ord = branch_mod.scalarOrder(target_canon, win_at);
        const dir: WindowDirection = if (ord == .lt) .undo else .redo;
        const rounds = if (ord == .lt) win_at.r -| target_canon.r else target_canon.r -| win_at.r;
        return .{ .dir = dir, .rounds = rounds, .slots = win.slots };
    }
    if (win.line) |wl| {
        if (target.branch != wl) return null;
    } else if (target.branch != win.start.branch) {
        return null;
    }
    const cmp_start = position_mod.compare(target, win.start) catch return null;
    if (cmp_start == .lt) return null;
    const cmp_end = position_mod.compare(target, win.end) catch return null;
    if (cmp_end == .gt) return null;
    const ord = position_mod.compare(target, win.at) catch return null;
    const dir: WindowDirection = if (ord == .lt) .undo else .redo;
    const rounds = if (ord == .lt) win.at.r -| target.r else target.r -| win.at.r;
    return .{ .dir = dir, .rounds = rounds, .slots = win.slots };
}

fn windowPlan(win: WindowCover, target: Position) Outcome {
    return .{
        .plan = .{
            .base = .{ .window = .{
                .position = target,
                .dir = win.dir,
                .slots = win.slots,
            } },
            .replay_rounds = win.rounds,
        },
    };
}

fn planPosition(target: Position, facts: Facts) Outcome {
    if (facts.graph) |graph| {
        if (graph.canonicalize(facts.active_line, target)) |target_canon| {
            const canon_current = graph.canonicalize(facts.active_line, facts.current) catch facts.current;
            const order = branch_mod.scalarOrder(target_canon, canon_current);
            if (order == .eq) return .{ .plan = .{ .base = .current, .replay_rounds = 0 } };
            if (windowCovers(facts, target)) |win| return windowPlan(win, target);
            const best = nearestOnLine(graph, facts.active_line, target, facts.checkpoints);
            if (order == .gt) {
                const live_rounds = target.r -| facts.current.r;
                if (best == null or live_rounds <= target.r -| best.?.position.r)
                    return .{ .plan = .{ .base = .current, .replay_rounds = live_rounds } };
                return checkpointPlan(best.?, target);
            }
            const chosen = best orelse return .{ .pending = .{ .what = "the reverse window's undo base" } };
            return checkpointPlan(chosen, target);
        } else |_| {
            return cross_seek.planCrossLine(graph, facts, target);
        }
    }
    const order = position_mod.compare(target, facts.current) catch
        return .{ .pending = .{ .what = "another line's seek" } };
    if (order == .eq) return .{ .plan = .{ .base = .current, .replay_rounds = 0 } };
    if (windowCovers(facts, target)) |win| return windowPlan(win, target);
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

/// Plans a backward step's base: the checkpoint at or before the
/// cursor, the one place a forward replay reaches both the cursor and
/// every stop before it. The cursor itself is never a backward step's
/// base, so with no checkpoint there the outcome stays pending naming
/// the reverse window's undo base (unit 21).
pub fn backBase(cursor: Position, facts: Facts) Outcome {
    if (windowCovers(facts, cursor)) |win| {
        const at_start = if (facts.graph) |graph| blk: {
            const c_canon = graph.canonicalize(facts.active_line, cursor) catch break :blk false;
            const s_canon = graph.canonicalize(facts.active_line, facts.window.?.start) catch break :blk false;
            break :blk branch_mod.scalarOrder(c_canon, s_canon) == .eq;
        } else (position_mod.compare(cursor, facts.window.?.start) catch .gt) == .eq;
        if (!at_start) {
            return .{ .plan = .{
                .base = .{ .window = .{
                    .position = cursor,
                    .dir = .undo,
                    .slots = 1,
                } },
                .replay_rounds = win.rounds,
            } };
        }
    }
    const best = if (facts.graph) |graph|
        nearestOnLine(graph, facts.active_line, cursor, facts.checkpoints)
    else
        nearestAtOrBefore(cursor, facts.checkpoints);
    const chosen = best orelse
        return .{ .pending = .{ .what = "the reverse window's undo base" } };
    return checkpointPlan(chosen, cursor);
}

fn nearestOnLine(
    graph: *const branch_mod.BranchGraph,
    active_line: branch_mod.BranchId,
    target: Position,
    checkpoints: []const Checkpoint,
) ?Checkpoint {
    var best: ?Checkpoint = null;
    var best_at: Position = .{};
    const target_canon = graph.canonicalize(active_line, target) catch return null;
    for (checkpoints) |c| {
        const c_canon = graph.canonicalize(active_line, c.position) catch continue;
        if (branch_mod.scalarOrder(c_canon, target_canon) == .gt) continue;
        if (best == null or branch_mod.scalarOrder(c_canon, best_at) == .gt) {
            best = c;
            best_at = c_canon;
        }
    }
    return best;
}

/// Plans a backward step's base when the machine has never stopped:
/// the cursor sits at or before every checkpoint, so the earliest one
/// is both base and landing, and the step settles with history_start.
pub fn backBaseAtStart(facts: Facts) Outcome {
    var best: ?Checkpoint = null;
    for (facts.checkpoints) |c| {
        const better = best == null or c.position.r < best.?.position.r;
        if (better) best = c;
    }
    const chosen = best orelse
        return .{ .pending = .{ .what = "the reverse window's undo base" } };
    return checkpointPlan(chosen, chosen.position);
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
