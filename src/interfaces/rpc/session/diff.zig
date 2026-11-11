//! State diff RPC handler (Slice 23.5): compares the machine at two
//! checkpoints or arbitrary positions of the session's history without
//! perturbing live session state.
const std = @import("std");
const rpc = @import("ra8_rpc_wire");
const proto = @import("rpc.zig");
const handlers = @import("handlers.zig");
const diff_wire = @import("diff_wire.zig");
const s = @import("ra8_session");
const api = s.api;
const branch_mod = s.history_branch;
const diff_engine = s.history_diff_engine;
const manifest_mod = s.history_manifest;
const object_id = s.history_object_id;
const position_mod = s.history_position;
const seek_engine = s.history_seek_engine;
const transport_mod = s.transport;

pub const DiffOutcome = rpc.Outcome(diff_wire.DiffWire);
const max_pages: usize = 200;

fn refuse() DiffOutcome {
    return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.refused)) };
}

const RankedCp = struct { cp: seek_engine.Checkpoint, rank: usize };

fn lessRanked(_: void, a: RankedCp, b: RankedCp) bool {
    return switch (branch_mod.scalarOrder(a.cp.position, b.cp.position)) {
        .lt => true,
        .gt => false,
        .eq => if (a.rank != b.rank) a.rank < b.rank else a.cp.id < b.cp.id,
    };
}

/// Returns ancestor-to-leaf rank when `pos` lies on `leaf`'s prefix chain, else null.
fn chainRank(graph: *const branch_mod.BranchGraph, leaf: u32, pos: position_mod.Position) !?usize {
    const cap = graph.nodes.count();
    if (!graph.nodes.contains(leaf)) return error.NoSuchBranch;
    var curr = leaf;
    var child_on_chain: ?u32 = null;
    var hops: usize = 0;
    while (true) : (hops += 1) {
        if (hops > cap) return error.InvalidForkPosition;
        const node = graph.get(curr) orelse return error.NoSuchBranch;
        if (curr == pos.branch) {
            if (curr != branch_mod.root_branch_id and branch_mod.scalarOrder(pos, node.fork_at) == .lt) return null;
            if (child_on_chain) |cid| {
                const cnode = graph.get(cid) orelse return error.NoSuchBranch;
                if (branch_mod.scalarOrder(pos, cnode.fork_at) == .gt) return null;
            }
            return cap - hops;
        }
        if (curr == branch_mod.root_branch_id) return null;
        child_on_chain = curr;
        curr = node.parent;
    }
}

fn lineCheckpoints(gpa: std.mem.Allocator, facts: seek_engine.Facts, branch: u32) ![]seek_engine.Checkpoint {
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
    for (ranked.items, 0..) |item, i| out[i] = item.cp;
    return out;
}

const ResolvedSide = union(enum) { checkpoint: seek_engine.Checkpoint, plan: seek_engine.Plan };

fn pickCheckpoint(line: []const seek_engine.Checkpoint, text: []const u8, cursor: position_mod.Position) ?seek_engine.Checkpoint {
    if (line.len == 0) return null;
    if (std.mem.eql(u8, text, "latest")) return line[line.len - 1];
    if (text.len == 0 or std.mem.eql(u8, text, "cursor")) {
        var best: ?seek_engine.Checkpoint = null;
        for (line) |c| if (branch_mod.scalarOrder(c.position, cursor) != .gt) {
            best = c;
        };
        return best;
    }
    if (std.mem.startsWith(u8, text, "chk:")) {
        const id = std.fmt.parseInt(u32, text[4..], 10) catch return null;
        for (line) |c| if (c.id == id) return c;
        return null;
    }
    const index = std.fmt.parseInt(usize, text, 10) catch return null;
    return if (index < line.len) line[index] else null;
}

fn fallbackCheckpointPlan(gpa: std.mem.Allocator, facts: seek_engine.Facts, target: position_mod.Position) ?seek_engine.Plan {
    const line_cps = lineCheckpoints(gpa, facts, target.branch) catch return null;
    defer gpa.free(line_cps);
    var best: ?seek_engine.Checkpoint = null;
    for (line_cps) |c| if (branch_mod.scalarOrder(c.position, target) != .gt) {
        best = c;
    };
    const cp = best orelse return null;
    return .{
        .base = .{ .checkpoint = .{ .id = cp.id, .object = cp.object, .position = cp.position, .touched = cp.touched } },
        .replay_rounds = target.r -| cp.position.r,
        .target = target,
    };
}

fn resolveSide(gpa: std.mem.Allocator, line: []const seek_engine.Checkpoint, all_facts: seek_engine.Facts, raw: []const u8, cursor: position_mod.Position) ?ResolvedSide {
    const text = std.mem.trim(u8, raw, " \t");
    if (text.len == 0 or std.mem.eql(u8, text, "cursor") or std.mem.eql(u8, text, "latest") or std.mem.startsWith(u8, text, "chk:")) {
        return .{ .checkpoint = pickCheckpoint(line, text, cursor) orelse return null };
    }
    if (std.fmt.parseInt(usize, text, 10)) |idx| return if (idx < line.len) .{ .checkpoint = line[idx] } else null else |_| {}

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
    const planned: seek_engine.Plan = switch (seek_engine.plan(parsed, plan_facts)) {
        .plan => |p| p,
        .pending => switch (parsed) {
            .position => |pt| fallbackCheckpointPlan(gpa, plan_facts, pt.position) orelse return null,
            else => return null,
        },
    };
    for (line) |c| if (c.position.branch == planned.target.branch and branch_mod.scalarOrder(c.position, planned.target) == .eq) {
        return .{ .checkpoint = c };
    };
    return .{ .plan = planned };
}

const Blobs = struct {
    gpa: std.mem.Allocator,
    bridge: transport_mod.Bridge,
    owned: std.ArrayList([]u8) = .empty,
    ephemeral: std.AutoHashMap([16]u8, []const u8),

    fn init(gpa: std.mem.Allocator, bridge: transport_mod.Bridge) Blobs {
        return .{ .gpa = gpa, .bridge = bridge, .ephemeral = std.AutoHashMap([16]u8, []const u8).init(gpa) };
    }

    fn deinit(self: *Blobs) void {
        self.ephemeral.deinit();
        for (self.owned.items) |bytes| self.gpa.free(bytes);
        self.owned.deinit(self.gpa);
    }

    fn putMem(context: *anyopaque, id: object_id.ObjectId, bytes: []const u8) anyerror!void {
        const self: *Blobs = @ptrCast(@alignCast(context));
        if (self.ephemeral.contains(id.bytes)) return;
        const copy = try self.gpa.dupe(u8, bytes);
        errdefer self.gpa.free(copy);
        try self.owned.append(self.gpa, copy);
        try self.ephemeral.put(id.bytes, copy);
    }

    fn get(context: *anyopaque, id: object_id.ObjectId) ?[]const u8 {
        const self: *Blobs = @ptrCast(@alignCast(context));
        if (self.ephemeral.get(id.bytes)) |mem| return mem;
        var name: [object_id.ObjectId.hex_len]u8 = undefined;
        id.formatHex(&name);
        const bytes = self.read(&name) orelse return null;
        self.owned.append(self.gpa, bytes) catch {
            self.gpa.free(bytes);
            return null;
        };
        return bytes;
    }

    fn read(self: *Blobs, name: []const u8) ?[]u8 {
        const reader = self.bridge.readObject orelse return null;
        return reader(self.bridge.context, self.gpa, name) catch null;
    }

    fn manifest(self: *Blobs, cp: seek_engine.Checkpoint) ?manifest_mod.Manifest {
        const name = manifest_mod.objectName(cp.object);
        const bytes = self.read(&name) orelse return null;
        defer self.gpa.free(bytes);
        return manifest_mod.decode(self.gpa, bytes) catch null;
    }
};

const RoundHalt = struct {
    session: *api.Session,
    target_r: u64,

    fn onRound(ctx: *anyopaque, at: seek_engine.Position) void {
        const self: *RoundHalt = @ptrCast(@alignCast(ctx));
        if (at.r < self.target_r) return;
        if (self.session.live.checkpoints) |cp| cp.stop = null;
        self.session.live.machine.requestHalt();
    }
};

fn stepToward(session: *api.Session, core: api.Core, at: position_mod.Position, target: position_mod.Position) !api.Ended {
    if (at.r < target.r) {
        var halt: RoundHalt = .{ .session = session, .target_r = target.r };
        if (session.live.checkpoints) |cp| cp.stop = .{ .context = &halt, .roundFn = &RoundHalt.onRound };
        defer if (session.live.checkpoints) |cp| {
            cp.stop = null;
        };
        try session.setRunBudget(core, 0);
        return session.run(core, .cont);
    }
    if (at.phase == target.phase and target.o > at.o) {
        const dist = target.o - at.o;
        if (target.gap == .polled and dist == 1) return session.run(core, .step);
        try session.setRunBudget(core, if (target.gap == .polled) dist - 1 else dist);
        return session.run(core, .cont);
    }
    return session.run(core, .step);
}

fn capturePlanned(gpa: std.mem.Allocator, session: *api.Session, bridge: transport_mod.Bridge, saved_live: []const u8, saved_line: u32, planned: seek_engine.Plan, blobs: *Blobs) !manifest_mod.Manifest {
    const files = (session.history orelse return error.NoHistory).files;
    switch (planned.base) {
        .current => {
            try files.readParts(saved_live, .{});
            if (session.fork_router) |r| r.switchActiveLine(saved_line);
            session.stampLine();
        },
        .checkpoint => |cp| {
            var obj_name: [32]u8 = undefined;
            transport_mod.objectName(cp.object, &obj_name);
            try bridge.restore(bridge.context, &obj_name);
        },
        .window => return error.UnsupportedBase,
    }
    var target_line = planned.target.branch;
    if (session.fork_router) |router| {
        if (router.graph) |g| if (g.canonicalize(saved_line, planned.target)) |_| {
            target_line = saved_line;
        } else |_| {};
        router.switchActiveLine(target_line);
        session.stampLine();
    }
    if (bridge.logBytes) |read_log| {
        try session.loadReplayInterventions(try read_log(bridge.context));
        s.fork.checkAndApplyReplayIntervention(session) catch {};
    }
    const core = session.currentCore();
    while (true) {
        const grid = session.grid orelse return error.NoGrid;
        const ord = session.comparePositions(grid.at, planned.target) catch return error.OtherLine;
        if (ord == .eq) break;
        if (ord == .gt) return error.OvershotTarget;
        const ended = try stepToward(session, core, grid.at, planned.target);
        switch (ended) {
            .count => {},
            .stop => |st| if (st != .stepped and st != .halt_requested) return error.UnexpectedStop,
            .core => return error.CoreFault,
        }
    }
    const grid = session.grid orelse return error.NoGrid;
    var pos = grid.at;
    pos.branch = target_line;
    if (session.fork_router) |r| if (r.graph) |g| {
        pos = g.canonicalize(target_line, grid.at) catch pos;
    };
    var engine = s.history_checkpoint_engine.CheckpointEngine.init(gpa);
    defer engine.deinit();
    var dirty = try s.history_dirty_pages.DirtyPages.init(gpa);
    defer dirty.deinit();
    return (try engine.captureFromFiles(files, &dirty, null, pos, 0, null, .{ .context = blobs, .putFn = &Blobs.putMem }, null)).manifest;
}

fn captureReadOnly(gpa: std.mem.Allocator, session: *api.Session, bridge: transport_mod.Bridge, side_a: ResolvedSide, side_b: ResolvedSide, blobs: *Blobs, man_a: *?manifest_mod.Manifest, man_b: *?manifest_mod.Manifest) !void {
    const files = (session.history orelse return error.NoHistory).files;
    var saved_live: std.Io.Writer.Allocating = try .initCapacity(gpa, 65536);
    defer saved_live.deinit();
    try files.writeTo(&saved_live.writer);
    const saved = .{
        .obs = files.store.observer,
        .win = session.window,
        .win_drv = session.window_driver,
        .nav = session.nav_index,
        .rounds = if (session.live.checkpoints) |cp| cp.rounds else null,
        .stop = if (session.live.checkpoints) |cp| cp.stop else null,
        .replaying = session.replaying,
        .fail = session.replay_failure,
        .line = if (session.fork_router) |r| r.active_line else 0,
        .grid_b = if (session.grid) |g| g.at.branch else 0,
        .budget = transport_mod.budgetOf(session, .cpu0),
        .breaks = session.live.machine.breaks,
        .watches = session.live.machine.watches,
    };
    files.store.observer = null;
    session.window = null;
    session.window_driver = null;
    session.nav_index = null;
    if (session.live.checkpoints) |cp| {
        cp.rounds = null;
        cp.stop = null;
    }
    session.live.machine.breaks = .{};
    session.live.machine.watches = .{};
    session.setReplaying(true);
    defer {
        s.history_replay_feeder.release(session);
        files.readParts(saved_live.written(), .{}) catch {};
        if (session.fork_router) |r| r.switchActiveLine(saved.line);
        if (session.grid) |g| @constCast(g).at.branch = saved.grid_b;
        session.setRunBudget(.cpu0, saved.budget) catch {};
        session.live.machine.breaks = saved.breaks;
        session.live.machine.watches = saved.watches;
        if (session.live.checkpoints) |cp| {
            cp.rounds = saved.rounds;
            cp.stop = saved.stop;
        }
        session.window = saved.win;
        session.window_driver = saved.win_drv;
        session.nav_index = saved.nav;
        session.replay_failure = saved.fail;
        session.setReplaying(saved.replaying);
        files.store.observer = saved.obs;
    }
    if (side_a == .plan) man_a.* = try capturePlanned(gpa, session, bridge, saved_live.written(), saved.line, side_a.plan, blobs);
    if (side_b == .plan) man_b.* = try capturePlanned(gpa, session, bridge, saved_live.written(), saved.line, side_b.plan, blobs);
}

fn resolveOrder(facts: seek_engine.Facts, a: position_mod.Position, b: position_mod.Position) diff_wire.LineOrder {
    if (facts.graph) |graph| {
        const leaf = if (graph.isAncestorOrSelf(a.branch, b.branch)) b.branch else if (graph.isAncestorOrSelf(b.branch, a.branch)) a.branch else return .other_line;
        const ok_a = (chainRank(graph, leaf, a) catch null) != null;
        const ok_b = (chainRank(graph, leaf, b) catch null) != null;
        if (ok_a and ok_b) return diff_wire.LineOrder.fromMathOrder(branch_mod.scalarOrder(a, b));
        return if (graph.compare(a, b)) |ord| diff_wire.LineOrder.fromMathOrder(ord) else |_| .other_line;
    }
    return if (position_mod.compare(a, b)) |ord| diff_wire.LineOrder.fromMathOrder(ord) else |_| .other_line;
}

pub fn diff(context: *handlers.Context, args: proto.DiffArgs) DiffOutcome {
    const gpa = context.gpa orelse return refuse();
    const plane = context.transport orelse return refuse();
    if (plane.busy() != null) return refuse();
    const bridge = plane.history orelse return refuse();
    var facts = bridge.facts(bridge.context) catch return refuse();
    if (context.session.fork_router) |router| {
        facts.graph = router.graph;
        facts.active_line = router.active_line;
    }
    if (context.session.nav_index) |nav| facts.nav = nav;
    const cursor = context.session.currentPosition();
    const line = lineCheckpoints(gpa, facts, cursor.branch) catch return refuse();
    defer gpa.free(line);
    const side_a = resolveSide(gpa, line, facts, args.a, cursor) orelse return refuse();
    const side_b = resolveSide(gpa, line, facts, args.b, cursor) orelse return refuse();

    var blobs = Blobs.init(gpa, bridge);
    defer blobs.deinit();
    var man_a: ?manifest_mod.Manifest = if (side_a == .checkpoint) blobs.manifest(side_a.checkpoint) orelse return refuse() else null;
    defer if (man_a) |*m| m.deinit(gpa);
    var man_b: ?manifest_mod.Manifest = if (side_b == .checkpoint) blobs.manifest(side_b.checkpoint) orelse return refuse() else null;
    defer if (man_b) |*m| m.deinit(gpa);
    if (side_a == .plan or side_b == .plan) {
        captureReadOnly(gpa, context.session, bridge, side_a, side_b, &blobs, &man_a, &man_b) catch return refuse();
    }
    var result = diff_engine.diffManifests(gpa, &(man_a orelse return refuse()), &(man_b orelse return refuse()), &Blobs.get, &blobs) catch return refuse();
    defer result.deinit(gpa);
    return encode(context, @intCast(@min(line.len, std.math.maxInt(u16))), resolveOrder(facts, result.pos_a, result.pos_b), &result) catch refuse();
}

fn encode(context: *handlers.Context, frames: u16, order: diff_wire.LineOrder, result: *const diff_engine.DiffResult) !DiffOutcome {
    const gpa = context.gpa.?;
    var regs: std.ArrayList(diff_wire.RegItem) = .empty;
    defer regs.deinit(gpa);
    for (result.cpu0_regs) |r| try regs.append(gpa, .{ .core = 0, .name = r.name, .val_a = r.val_a, .val_b = r.val_b });
    for (result.cpu1_regs) |r| try regs.append(gpa, .{ .core = 1, .name = r.name, .val_a = r.val_a, .val_b = r.val_b });
    var pages: std.ArrayList(diff_wire.PageItem) = .empty;
    defer pages.deinit(gpa);
    for (result.pages[0..@min(result.pages.len, max_pages)]) |p| try pages.append(gpa, .{
        .space = @backingInt(p.space),
        .page_index = p.page_index,
        .address = p.address,
        .has_a = @intFromBool(p.obj_a != null),
        .obj_a = if (p.obj_a) |o| o.bytes else @splat(0),
        .has_b = @intFromBool(p.obj_b != null),
        .obj_b = if (p.obj_b) |o| o.bytes else @splat(0),
    });
    var periphs: std.ArrayList(diff_wire.PeriphItem) = .empty;
    defer periphs.deinit(gpa);
    for (result.periphs) |p| try periphs.append(gpa, .{ .unit = p.unit, .offset = p.offset, .old_val = p.old_val, .new_val = p.new_val, .changed_bytes = p.changed_bytes });
    var writer: std.Io.Writer = .fixed(context.scratch);
    try diff_wire.encodeSidesOrdered(&writer, frames, .fromPosition(result.pos_a), .fromPosition(result.pos_b), order, regs.items, pages.items, periphs.items);
    return .{ .ok = .{ .bytes = writer.buffered() } };
}
