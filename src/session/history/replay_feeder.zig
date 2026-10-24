//! Feeder for scheduled interventions during history replay (Slice 20.3).
//!
//! Reconstructs interventions recorded in committed log frames along the
//! active execution line, orders them by canonical position, and supplies them
//! to the session to be re-applied at their exact positions without re-recording.
const std = @import("std");
const branch_mod = @import("branch.zig");
const position_mod = @import("position.zig");
const record_mod = @import("record.zig");
const replay_mod = @import("replay.zig");
const fork_router_mod = @import("fork_router.zig");
const input_script = @import("ra8_components").input_script;
const core_view = @import("../core_view.zig");

pub const Action = fork_router_mod.Action;
pub const Position = position_mod.Position;
pub const BranchId = branch_mod.BranchId;
pub const BranchGraph = branch_mod.BranchGraph;
pub const Intervention = record_mod.Intervention;

pub const ScheduledIntervention = struct {
    position: Position,
    action: Action,
};

pub const EncodedAction = struct {
    what: Intervention.What,
    body: []const u8,
};

/// Encodes a Session Action into an intervention record payload.
pub fn encodeAction(allocator: std.mem.Allocator, action: Action) !EncodedAction {
    switch (action) {
        .register => |reg| {
            const body = try allocator.alloc(u8, 8);
            std.mem.writeInt(u32, body[0..4], @backingInt(reg.which), .little);
            std.mem.writeInt(u32, body[4..8], reg.value, .little);
            return .{ .what = .register_write, .body = body };
        },
        .memory => |mem| {
            const body = try allocator.alloc(u8, 4 + mem.bytes.len);
            std.mem.writeInt(u32, body[0..4], mem.address, .little);
            @memcpy(body[4..], mem.bytes);
            return .{ .what = .memory_write, .body = body };
        },
        .input => |inp| {
            var buf: [input_script.max_body_len]u8 = undefined;
            var writer = std.Io.Writer.fixed(&buf);
            try input_script.encodeBody(&writer, inp.event);
            const what: Intervention.What = switch (inp.event) {
                .button => .button,
                else => .tap,
            };
            return .{ .what = what, .body = try allocator.dupe(u8, writer.buffered()) };
        },
        .console => |con| return .{ .what = .keystroke, .body = try allocator.dupe(u8, con.bytes) },
        .plug => |p| return .{
            .what = if (p.name != null) .plug else .unplug,
            .body = if (p.name) |n| try allocator.dupe(u8, n) else &[_]u8{},
        },
        .fault => return .{ .what = .fault, .body = &[_]u8{} },
        .camera => |cam| return .{ .what = .camera_change, .body = try allocator.dupe(u8, cam.spec) },
        .skip_bkpt => return .{ .what = .skip_bkpt, .body = &[_]u8{} },
        .load => |ld| return .{ .what = .load, .body = try allocator.dupe(u8, ld.image) },
    }
}

/// Frees memory allocated by encodeAction.
pub fn freeEncodedAction(allocator: std.mem.Allocator, encoded: *EncodedAction) void {
    if (encoded.body.len > 0) allocator.free(encoded.body);
    encoded.* = undefined;
}

/// Decodes an intervention record back into a Session Action.
pub fn decodeAction(allocator: std.mem.Allocator, what: Intervention.What, body: []const u8) !Action {
    switch (what) {
        .register_write => {
            if (body.len < 8) return error.Truncated;
            const raw_reg = std.mem.readInt(u32, body[0..4], .little);
            const val = std.mem.readInt(u32, body[4..8], .little);
            if (raw_reg > std.math.maxInt(u6)) return error.BadValue;
            const which: core_view.Cortex = @fromBackingInt(@intCast(@as(u6, @intCast(raw_reg))));
            return .{ .register = .{ .core = .cpu0, .which = which, .value = val } };
        },
        .memory_write => {
            if (body.len < 4) return error.Truncated;
            const addr = std.mem.readInt(u32, body[0..4], .little);
            const bytes = try allocator.dupe(u8, body[4..]);
            return .{ .memory = .{ .core = .cpu0, .address = addr, .bytes = bytes } };
        },
        .tap, .button => {
            const event = try input_script.decodeBody(body);
            return .{ .input = .{ .core = .cpu0, .at_ns = 0, .event = event } };
        },
        .keystroke => {
            const bytes = try allocator.dupe(u8, body);
            return .{ .console = .{ .core = .cpu0, .bytes = bytes } };
        },
        .camera_change => {
            const spec = try allocator.dupe(u8, body);
            return .{ .camera = .{ .core = .cpu0, .spec = spec } };
        },
        .load => {
            const img = try allocator.dupe(u8, body);
            return .{ .load = .{ .core = .cpu0, .image = img } };
        },
        .skip_bkpt => return .{ .skip_bkpt = .{ .core = .cpu0 } },
        else => return error.BadValue,
    }
}

pub const ReplayFeeder = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(ScheduledIntervention),
    cursor: usize = 0,

    pub fn init(allocator: std.mem.Allocator) ReplayFeeder {
        return .{
            .allocator = allocator,
            .items = std.ArrayList(ScheduledIntervention).empty,
            .cursor = 0,
        };
    }

    pub fn deinit(self: *ReplayFeeder) void {
        self.reset();
    }

    pub fn reset(self: *ReplayFeeder) void {
        for (self.items.items) |*item| {
            fork_router_mod.freeAction(self.allocator, &item.action);
        }
        self.items.deinit(self.allocator);
        self.items = std.ArrayList(ScheduledIntervention).empty;
        self.cursor = 0;
    }

    pub fn loadFromLog(
        self: *ReplayFeeder,
        graph: ?*const BranchGraph,
        active_line: BranchId,
        log_bytes: []const u8,
    ) !void {
        self.reset();
        var ctx = ScanContext{
            .feeder = self,
            .graph = graph,
            .active_line = active_line,
        };
        _ = try replay_mod.replay(log_bytes, &ctx, visitRecord);
        std.mem.sort(ScheduledIntervention, self.items.items, {}, sortLess);
    }

    pub fn peekDue(self: *ReplayFeeder, pos: Position) ?ScheduledIntervention {
        if (self.cursor >= self.items.items.len) return null;
        const next = self.items.items[self.cursor];
        const ord = branch_mod.scalarOrder(next.position, pos);
        if (ord == .eq) return next;
        return null;
    }

    pub fn advance(self: *ReplayFeeder) void {
        if (self.cursor < self.items.items.len) self.cursor += 1;
    }

    pub fn nextPosition(self: *ReplayFeeder) ?Position {
        if (self.cursor >= self.items.items.len) return null;
        return self.items.items[self.cursor].position;
    }

    pub fn seekTo(self: *ReplayFeeder, pos: Position) void {
        self.cursor = 0;
        while (self.cursor < self.items.items.len) : (self.cursor += 1) {
            const ord = branch_mod.scalarOrder(self.items.items[self.cursor].position, pos);
            if (ord != .lt) break;
        }
    }

    pub fn count(self: *const ReplayFeeder) usize {
        return self.items.items.len;
    }

    pub fn isEmpty(self: *const ReplayFeeder) bool {
        return self.items.items.len == 0;
    }

    pub fn checkAndApply(self: *ReplayFeeder, session: *api.Session) !void {
        const cur_pos = session.currentPosition();
        while (self.peekDue(cur_pos)) |item| {
            const prior = session.replaying;
            session.setReplaying(true);
            defer session.setReplaying(prior);
            try @import("../fork.zig").applyAction(session, item.action);
            self.advance();
        }
    }
};

const api = @import("../api.zig");

pub fn loadSessionInterventions(session: *api.Session, log_bytes: []const u8) !void {
    const router = session.fork_router orelse return;
    if (session.replay_feeder == null) {
        session.replay_feeder = ReplayFeeder.init(router.allocator);
    }
    try session.replay_feeder.?.loadFromLog(router.graph, router.active_line, log_bytes);
    session.replay_feeder.?.seekTo(session.currentPosition());
}

const ScanContext = struct {
    feeder: *ReplayFeeder,
    graph: ?*const BranchGraph,
    active_line: BranchId,
};

fn visitRecord(ctx: *ScanContext, entry: replay_mod.Entry) anyerror!void {
    switch (entry) {
        .intervention => |hit| {
            const raw_pos = hit.header.position;
            const canon_pos = if (ctx.graph) |g|
                g.canonicalize(ctx.active_line, raw_pos) catch return
            else blk: {
                if (raw_pos.branch != ctx.active_line) return;
                break :blk raw_pos;
            };
            const action = decodeAction(ctx.feeder.allocator, hit.intervention.what, hit.intervention.body) catch return;
            try ctx.feeder.items.append(ctx.feeder.allocator, .{
                .position = canon_pos,
                .action = action,
            });
        },
        else => {},
    }
}

fn sortLess(_: void, a: ScheduledIntervention, b: ScheduledIntervention) bool {
    return branch_mod.scalarOrder(a.position, b.position) == .lt;
}
