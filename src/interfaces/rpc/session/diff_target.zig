//! Resolve diff sides against checkpoints and history positions.
const s = @import("ra8_session");
const std = @import("std");

const branch_mod = s.history_branch;
const position_mod = s.history_position;
const seek_engine = s.history_seek_engine;

const RankedCp = struct { cp: seek_engine.Checkpoint, rank: usize };

fn lessRanked(_: void, a: RankedCp, b: RankedCp) bool {
    return switch (branch_mod.scalarOrder(a.cp.position, b.cp.position)) {
        .lt => true,
        .gt => false,
        .eq => if (a.rank != b.rank) a.rank < b.rank else a.cp.id < b.cp.id,
    };
}

/// Returns ancestor-to-leaf rank when `pos` lies on `leaf`'s prefix chain, else null.
pub fn chainRank(graph: *const branch_mod.BranchGraph, leaf: u32, pos: position_mod.Position) !?usize {
    const cap = graph.nodes.count();
    if (!graph.nodes.contains(leaf)) return error.NoSuchBranch;
    var curr = leaf;
    var child_on_chain: ?u32 = null;
    var hops: usize = 0;
    while (true) : (hops += 1) {
        if (hops > cap) return error.InvalidForkPosition;
        const node = graph.get(curr) orelse return error.NoSuchBranch;
        if (curr == pos.branch) {
            if (!try onPrefix(graph, node, curr, child_on_chain, pos)) return null;
            return cap - hops;
        }
        if (curr == branch_mod.root_branch_id) return null;
        child_on_chain = curr;
        curr = node.parent;
    }
}

fn onPrefix(
    graph: *const branch_mod.BranchGraph,
    node: branch_mod.BranchNode,
    curr: u32,
    child_on_chain: ?u32,
    pos: position_mod.Position,
) !bool {
    if (curr != branch_mod.root_branch_id and branch_mod.scalarOrder(pos, node.fork_at) == .lt) return false;
    if (child_on_chain) |cid| {
        const cnode = graph.get(cid) orelse return error.NoSuchBranch;
        if (branch_mod.scalarOrder(pos, cnode.fork_at) == .gt) return false;
    }
    return true;
}

pub fn lineCheckpoints(gpa: std.mem.Allocator, facts: seek_engine.Facts, branch: u32) ![]seek_engine.Checkpoint {
    var ranked: std.ArrayList(RankedCp) = .empty;
    defer ranked.deinit(gpa);
    for (facts.checkpoints) |c| {
        const rank = if (facts.graph) |graph|
            (try chainRank(graph, branch, c.position)) orelse continue
        else if (c.position.branch == branch) @as(usize, 0) else continue;
        try ranked.append(gpa, .{ .cp = c, .rank = rank });
    }
    std.mem.sort(RankedCp, ranked.items, {}, lessRanked);
    const out = try gpa.alloc(seek_engine.Checkpoint, ranked.items.len);
    for (ranked.items, 0..) |item, i| {
        out[i] = item.cp;
    }
    return out;
}

pub const ResolvedSide = union(enum) { checkpoint: seek_engine.Checkpoint, plan: seek_engine.Plan };

fn pickCheckpoint(
    line: []const seek_engine.Checkpoint,
    text: []const u8,
    cursor: position_mod.Position,
) ?seek_engine.Checkpoint {
    if (line.len == 0) return null;
    if (std.mem.eql(u8, text, "latest")) return line[line.len - 1];
    if (text.len == 0 or std.mem.eql(u8, text, "cursor")) {
        return checkpointBefore(line, cursor);
    }
    if (std.mem.startsWith(u8, text, "chk:")) {
        const id = std.fmt.parseInt(u32, text[4..], 10) catch return null;
        for (line) |c| if (c.id == id) return c;
        return null;
    }
    const index = std.fmt.parseInt(usize, text, 10) catch return null;
    return if (index < line.len) line[index] else null;
}

fn fallbackCheckpointPlan(
    gpa: std.mem.Allocator,
    facts: seek_engine.Facts,
    target: position_mod.Position,
) ?seek_engine.Plan {
    const line_cps = lineCheckpoints(gpa, facts, target.branch) catch return null;
    defer gpa.free(line_cps);
    const cp = checkpointBefore(line_cps, target) orelse return null;
    return .{
        .base = .{
            .checkpoint = .{
                .id = cp.id,
                .object = cp.object,
                .position = cp.position,
                .touched = cp.touched,
            },
        },
        .replay_rounds = target.r -| cp.position.r,
        .target = target,
    };
}

pub fn resolveSide(
    gpa: std.mem.Allocator,
    line: []const seek_engine.Checkpoint,
    all_facts: seek_engine.Facts,
    raw: []const u8,
    cursor: position_mod.Position,
) ?ResolvedSide {
    const text = std.mem.trim(u8, raw, " \t");
    if (text.len == 0 or
        std.mem.eql(u8, text, "cursor") or
        std.mem.eql(u8, text, "latest") or
        std.mem.startsWith(u8, text, "chk:"))
    {
        return .{ .checkpoint = pickCheckpoint(line, text, cursor) orelse return null };
    }
    if (std.fmt.parseInt(usize, text, 10)) |idx| return if (idx < line.len)
        .{ .checkpoint = line[idx] }
    else
        null else |_| {}

    const planned = planSide(gpa, all_facts, text, cursor) orelse return null;
    for (line) |c| if (c.position.branch == planned.target.branch and
        branch_mod.scalarOrder(c.position, planned.target) == .eq)
    {
        return .{ .checkpoint = c };
    };
    return .{ .plan = planned };
}

fn checkpointBefore(line: []const seek_engine.Checkpoint, target: position_mod.Position) ?seek_engine.Checkpoint {
    var best: ?seek_engine.Checkpoint = null;
    for (line) |checkpoint| {
        if (branch_mod.scalarOrder(checkpoint.position, target) != .gt) best = checkpoint;
    }
    return best;
}

fn planSide(
    gpa: std.mem.Allocator,
    all_facts: seek_engine.Facts,
    text: []const u8,
    cursor: position_mod.Position,
) ?seek_engine.Plan {
    var parsed = s.history_seek_target.parse(text) catch return null;
    switch (parsed) {
        .position => |*pt| if (!pt.branch_named) {
            pt.position.branch = cursor.branch;
            pt.branch_named = true;
        },
        else => {},
    }
    var plan_facts = all_facts;
    plan_facts.window = null;
    return switch (seek_engine.plan(parsed, plan_facts)) {
        .plan => |p| p,
        .pending => switch (parsed) {
            .position => |pt| fallbackCheckpointPlan(gpa, plan_facts, pt.position) orelse return null,
            else => return null,
        },
    };
}
