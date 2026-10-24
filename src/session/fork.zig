//! Session-level fork routing choke point and intervention execution (Slice 20.2).
const std = @import("std");
const api = @import("api.zig");
const fork_router_mod = @import("history/fork_router.zig");
const branch_mod = @import("history/branch.zig");
const branches_codec = @import("history/branches_codec.zig");
const history_root = @import("history/root.zig");
const history_record = @import("history/record.zig");
const history_position = @import("history/position.zig");
const elf = @import("ra8_board").image.elf;
const symbols = @import("symbols.zig");
const widget_tree = @import("widget_tree.zig");
const input_script = @import("ra8_components").input_script;
const replay_feeder = @import("history/replay_feeder.zig");
const async_traffic = @import("history/async_traffic.zig");

const Session = api.Session;
const Core = api.Core;
const Register = api.Register;
const Endpoint = api.Endpoint;
const FaultMode = api.FaultMode;

pub const ForkRouter = fork_router_mod.ForkRouter;
pub const PendingFork = fork_router_mod.PendingFork;
pub const Action = fork_router_mod.Action;
pub const RouteDecision = fork_router_mod.RouteDecision;
pub const ForkReason = history_record.ForkReason;
pub const Position = history_position.Position;

pub const fork_types = @import("fork_types.zig");
pub const NetHook = fork_types.NetHook;
pub const ConsoleHook = fork_types.ConsoleHook;
pub const CameraHook = fork_types.CameraHook;
pub const GraphSink = fork_types.GraphSink;

/// Resolves the current session position with line-aware branch id.
pub fn currentPosition(self: *const Session) Position {
    if (self.grid) |grid| {
        var p = grid.at;
        if (self.fork_router) |router| p.branch = router.active_line;
        return p;
    }
    return .{
        .branch = if (self.fork_router) |router| router.active_line else 0,
        .r = 0,
        .phase = .cpu0,
        .o = 0,
        .gap = .retired,
    };
}

/// Updates the recorded end position of the active branch canonically as execution advances.
pub fn notePosition(self: *Session, pos: Position) void {
    if (self.replaying) return;
    const router = self.fork_router orelse return;
    const graph = router.graph orelse return;
    const canon_pos = graph.canonicalize(router.active_line, pos) catch pos;
    if (graph.get(router.active_line)) |mut_node| {
        var node = mut_node;
        const ord = branch_mod.scalarOrder(canon_pos, node.recorded_end);
        if (ord == .gt) {
            node.recorded_end = canon_pos;
            graph.insertNode(node) catch {};
        }
    }
}

pub fn setReplaying(self: *Session, replaying: bool) void {
    self.replaying = replaying;
    if (self.history) |h| h.replaying = replaying;
    if (self.persistent_recorder) |rec| rec.replaying = replaying;
}

fn recordActionIntervention(self: *Session, pos: Position, action: Action) anyerror!void {
    if (self.replaying) return;
    const router = self.fork_router;
    const allocator = if (router) |r| r.allocator else if (self.persistent_recorder) |rec| rec.gpa else return;
    var encoded = try replay_feeder.encodeAction(allocator, action);
    defer replay_feeder.freeEncodedAction(allocator, &encoded);
    const seq = if (router) |r| r.nextSeq() else if (self.history) |h| h.seq else 0;
    if (self.history) |h| h.seq += 1;
    if (self.persistent_recorder) |rec| {
        try rec.recordIntervention(.{ .position = pos, .seq = seq }, .{ .what = encoded.what, .body = encoded.body });
    } else if (self.history) |h| {
        try h.recordIntervention(pos, encoded.what, encoded.body);
    }
}

/// Dispatches an action onto the machine without routing checks.
pub fn applyAction(self: *Session, action: Action) anyerror!void {
    switch (action) {
        .register => |reg| {
            try (try self.view(reg.core)).setRegister(reg.which, reg.value);
            self.dirty();
            self.publish(.{ .core = reg.core, .kind = .register_written });
        },
        .memory => |mem| {
            try (try self.view(mem.core)).write(mem.address, mem.bytes);
            self.dirty();
            self.publish(.{ .core = mem.core, .kind = .memory_written, .address = mem.address });
        },
        .input => |inp| {
            try self.select(inp.core);
            const script = self.input_script orelse return api.Error.NoInput;
            try script.schedule(.{ .at_ns = inp.at_ns, .event = inp.event });
            self.publish(.{ .core = inp.core, .kind = .input_scheduled });
        },
        .console => |con| {
            try self.select(con.core);
            if (self.console_hook) |hook| {
                try hook.feedFn(hook.context, con.bytes);
            }
            self.publish(.{ .core = con.core, .kind = .console_input });
        },
        .plug => |p| {
            const hook = self.plugs orelse return api.Error.NoPlugs;
            try hook.plugFn(hook.context, p.at, p.name);
            self.publish(.{ .core = p.core, .kind = if (p.name != null) .plugged else .unplugged });
        },
        .fault => |f| {
            const faults = self.faults orelse return api.Error.NoFaults;
            try faults.set(f.at, f.mode);
            self.publish(.{ .core = f.core, .kind = if (f.mode != null) .fault_set else .fault_cleared });
        },
        .camera => |cam| {
            try self.select(cam.core);
            if (self.camera_hook) |hook| {
                try hook.changeFn(hook.context, cam.spec);
            }
            self.publish(.{ .core = cam.core, .kind = .camera_changed });
        },
        .skip_bkpt => |sk| {
            try self.select(sk.core);
            const view = try self.view(sk.core);
            const pc = try view.register(.pc);
            try view.setRegister(.pc, pc + 2);
            self.dirty();
            self.publish(.{ .core = sk.core, .kind = .bkpt_skipped, .address = pc });
        },
        .load => |ld| {
            try self.select(ld.core);
            const loader = self.loader orelse return api.Error.NoLoader;
            try loader.loadFn(loader.context, ld.core, ld.image);
            self.dirty();
            const tree_address = if (elf.Image.init(ld.image)) |parsed| symbols.addressOf(parsed, widget_tree.symbol) else |_| null;
            self.widget_tree_addresses[@backingInt(ld.core)] = tree_address;
            self.publish(.{ .core = ld.core, .kind = .loaded });
        },
    }
}

/// Executes a branch fork from a past cursor position.
pub fn executeFork(self: *Session, reason: ForkReason, fork_pos: Position, action: Action) anyerror!void {
    const router = self.fork_router orelse return;
    const now_ns = if (self.event_clock) |clock| clock.nowFn(clock.context) else self.now() catch 0;
    const old_branch = router.active_line;
    var new_branch_id: u32 = old_branch;
    if (router.graph) |graph| {
        new_branch_id = try graph.addBranch(old_branch, fork_pos, reason, now_ns);
    }
    if (self.persistent_recorder) |rec| {
        try rec.switchSegment(now_ns, new_branch_id, 0);
        try rec.recordBranch(
            .{ .position = fork_pos, .seq = router.nextSeq() },
            .{ .id = new_branch_id, .parent = old_branch, .fork_at = fork_pos, .reason = reason },
        );
    }
    if (self.graph_sink) |sink| {
        if (router.graph) |graph| {
            var allocating = try std.Io.Writer.Allocating.initCapacity(router.allocator, 1024);
            defer allocating.deinit();
            try branches_codec.encode(graph, &allocating.writer);
            sink.writeFn(sink.context, allocating.written()) catch |err| {
                _ = graph.nodes.remove(new_branch_id);
                if (graph.next_branch_id == new_branch_id + 1) graph.next_branch_id = new_branch_id;
                return err;
            };
        }
    }
    if (router.graph) |graph| {
        graph.active_branch = new_branch_id;
        router.active_line = new_branch_id;
    }
    try applyAction(self, action);
    try recordActionIntervention(self, fork_pos, action);
    if (self.net_hook) |hook| {
        hook.closeFlowsFn(hook.context);
    }
    _ = async_traffic.clearOnFork(self);
}

/// The single Session-level routing choke point for host interventions.
pub fn routeIntervention(self: *Session, core: Core, reason: ForkReason, action: Action) anyerror!void {
    _ = core;
    if (self.replaying) {
        try applyAction(self, action);
        return;
    }
    const router = self.fork_router orelse {
        try applyAction(self, action);
        try recordActionIntervention(self, currentPosition(self), action);
        return;
    };
    const cursor = self.currentPosition();
    const recorded_end = router.recordedEnd();
    const decision = fork_router_mod.decide(
        router.graph,
        router.active_line,
        cursor,
        recorded_end,
        router.first_fork_confirmed,
        reason,
    );
    switch (decision) {
        .live => {
            try applyAction(self, action);
            try recordActionIntervention(self, cursor, action);
        },
        .needs_confirmation => {
            try router.setPending(reason, cursor, action);
            return error.ForkNeedsConfirmation;
        },
        .fork => try executeFork(self, reason, cursor, action),
    }
}

/// Returns details of any pending fork awaiting user confirmation.
pub fn forkPending(self: *const Session) ?PendingFork {
    if (self.fork_router) |router| {
        return router.pending_fork;
    }
    return null;
}

/// Confirms the pending fork, executes it, and applies the intervention.
pub fn confirmFork(self: *Session) anyerror!void {
    const router = self.fork_router orelse return error.NoHistory;
    var pending = router.popPending() orelse return error.NoPendingFork;
    defer fork_router_mod.freeAction(router.allocator, &pending.action);
    try executeFork(self, pending.reason, pending.position, pending.action);
    router.first_fork_confirmed = true;
}

/// Cancels the pending fork, clearing it without mutating state.
pub fn cancelFork(self: *Session) void {
    if (self.fork_router) |router| {
        router.cancel();
    }
}

pub fn setRegister(self: *Session, core: Core, which: Register, value: u32) anyerror!void {
    return routeIntervention(self, core, .writes, .{ .register = .{ .core = core, .which = which, .value = value } });
}

pub fn write(self: *Session, core: Core, address: u32, bytes: []const u8) anyerror!void {
    return routeIntervention(self, core, .writes, .{ .memory = .{ .core = core, .address = address, .bytes = bytes } });
}

pub fn scheduleInput(self: *Session, core: Core, at_ns: u64, event: input_script.Event) anyerror!void {
    const reason: ForkReason = switch (event) {
        .button => .buttons,
        else => .taps,
    };
    return routeIntervention(self, core, reason, .{ .input = .{ .core = core, .at_ns = at_ns, .event = event } });
}

pub fn consoleInput(self: *Session, core: Core, bytes: []const u8) anyerror!void {
    return routeIntervention(self, core, .keystrokes, .{ .console = .{ .core = core, .bytes = bytes } });
}

pub fn plug(self: *Session, core: Core, at: Endpoint, name: []const u8) anyerror!void {
    return routeIntervention(self, core, .plug_unplug_fault, .{ .plug = .{ .core = core, .at = at, .name = name } });
}

pub fn unplug(self: *Session, core: Core, at: Endpoint) anyerror!void {
    return routeIntervention(self, core, .plug_unplug_fault, .{ .plug = .{ .core = core, .at = at, .name = null } });
}

pub fn setFault(self: *Session, core: Core, at: Endpoint, mode: FaultMode) anyerror!void {
    return routeIntervention(self, core, .plug_unplug_fault, .{ .fault = .{ .core = core, .at = at, .mode = mode } });
}

pub fn clearFault(self: *Session, core: Core, at: Endpoint) anyerror!void {
    return routeIntervention(self, core, .plug_unplug_fault, .{ .fault = .{ .core = core, .at = at, .mode = null } });
}

pub fn changeCamera(self: *Session, core: Core, spec: []const u8) anyerror!void {
    return routeIntervention(self, core, .camera_change, .{ .camera = .{ .core = core, .spec = spec } });
}

pub fn skipBkpt(self: *Session, core: Core) anyerror!void {
    return routeIntervention(self, core, .skip_bkpt, .{ .skip_bkpt = .{ .core = core } });
}

pub fn run(self: *Session, core: Core, command: api.Run) anyerror!api.Ended {
    try self.select(core);
    self.grid = if (self.live.boundary) |edge| edge.saved orelse &self.live.saved else null;
    try checkAndApplyReplayIntervention(self);
    const retired_before = self.live.core.cpu.retired;
    if (self.replay_feeder) |*feeder| {
        if (feeder.nextPosition()) |next_pos| {
            const cur_pos = currentPosition(self);
            if (cur_pos.r == next_pos.r and cur_pos.phase == next_pos.phase and next_pos.o > cur_pos.o) {
                const dist = next_pos.o - cur_pos.o;
                if (self.live.budget > dist) self.live.budget = dist;
            }
        }
    }
    const ended = try self.live.go(command);
    if (self.live.boundary == null) try advanceBoard(self, core, self.live.core.cpu.retired - retired_before);
    notePosition(self, self.currentPosition());
    try checkAndApplyReplayIntervention(self);
    _ = try async_traffic.drainIfNeeded(self);
    const stopped: Core = @fromBackingInt(@intCast(self.live.ended_index));
    self.publish(.{ .core = stopped, .kind = .stopped, .ended = ended });
    if (self.history) |h| try recordStop(self, h, core, stopped, ended);
    if (ended == .core) {
        const address: ?u32 = switch (ended.core) {
            .count => null,
            .unknown => |instruction| instruction.address,
            inline else => |at| at,
        };
        self.publish(.{ .core = stopped, .kind = .fault, .address = address, .payload = .{ .fault = .{ .cause = @backingInt(std.meta.activeTag(ended.core)), .address = address } } });
    }
    return ended;
}

pub fn comparePositions(self: *const Session, a: Position, b: Position) anyerror!std.math.Order {
    if (self.fork_router) |router| {
        if (router.graph) |graph| {
            return graph.compareOnLine(router.active_line, a, b);
        }
    }
    return history_position.compare(a, b);
}

pub fn checkAndApplyReplayIntervention(self: *Session) anyerror!void {
    if (self.replay_feeder) |*feeder| try feeder.checkAndApply(self);
}

pub fn loadReplayInterventions(self: *Session, log_bytes: []const u8) anyerror!void {
    return replay_feeder.loadSessionInterventions(self, log_bytes);
}

pub fn advanceBoard(self: *Session, core: Core, instructions: u64) anyerror!void {
    const board = self.board_ticks[@backingInt(core)] orelse return;
    var left = instructions;
    while (left > 0) {
        const count: u32 = @intCast(@min(left, std.math.maxInt(u32)));
        try board.tick.run(board.guest, count);
        left -= count;
    }
}

pub fn recordStop(self: *Session, h: *api.History, asked: Core, stopped: Core, ended: api.Ended) anyerror!void {
    if (self.replaying) return;
    const stopped_pc: u32 = if (stopped == asked) self.live.core.cpu.regs.pc else self.live.other.?.core.cpu.regs.pc;
    const tag: u16 = if (ended == .core) 1 else 0;
    const at_ns = if (self.event_clock) |clock| clock.nowFn(clock.context) else 0;
    try h.capture(stopped_pc, tag, at_ns);
}

pub fn load(self: *Session, core: Core, image: []const u8) anyerror!void {
    if (self.root) |root| {
        const id = history_root.identity(image);
        const expected_id = switch (core) {
            .cpu0 => root.elf0.identity,
            .cpu1 => if (root.elf1) |e1| e1.identity else return error.DifferentImage,
        };
        if (!std.mem.eql(u8, &expected_id, &id)) {
            return error.DifferentImage;
        }
    } else if (self.fork_router != null) {
        const id = history_root.identity(image);
        const idx = @as(usize, @backingInt(core));
        if (self.image_identity[idx]) |expected_id| {
            if (!std.mem.eql(u8, &expected_id, &id)) {
                return error.DifferentImage;
            }
        } else {
            self.image_identity[idx] = id;
        }
    }
    return routeIntervention(self, core, .load, .{ .load = .{ .core = core, .image = image } });
}
