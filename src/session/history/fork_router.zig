//! Pure decision logic and data types for intervention fork routing (Slice 20.2).
//!
//! Interventions crossing into Session are checked against the active line's
//! recorded end. If the cursor is at or after recorded end (or no history is
//! attached), the intervention is live. If the cursor is in the past:
//! 1. The first past fork requires confirmation (error.ForkNeedsConfirmation),
//!    recording the pending fork details.
//! 2. Once confirmed (or on later forks in the same session), a fork creates
//!    a new branch in the graph, emits a Branch record into the log,
//!    disconnects the C6 network, switches the recorder to a new segment,
//!    and applies the intervention.

const std = @import("std");
const branch_mod = @import("branch.zig");
const history_position = @import("position.zig");
const history_record = @import("record.zig");
const session_root = @import("../root.zig");
const stream = session_root.event.stream;
const core_view = session_root.core_view;
const endpoint = @import("ra8_components").endpoint;
const fault_spec = @import("ra8_components").fault.spec;
const input_script = @import("ra8_components").input_script;

pub const Position = history_position.Position;
pub const ForkReason = history_record.ForkReason;
pub const BranchId = branch_mod.BranchId;
pub const BranchGraph = branch_mod.BranchGraph;
pub const Core = stream.Core;
pub const Register = core_view.Cortex;
pub const Endpoint = endpoint.Endpoint;
pub const FaultMode = fault_spec.Mode;

/// What mutation was requested by the host intervention.
pub const Action = union(enum) {
    register: struct { core: Core, which: Register, value: u32 },
    memory: struct { core: Core, address: u32, bytes: []const u8 },
    input: struct { core: Core, at_ns: u64, event: input_script.Event },
    console: struct { core: Core, bytes: []const u8 },
    plug: struct { core: Core, at: Endpoint, name: ?[]const u8 },
    fault: struct { core: Core, at: Endpoint, mode: ?FaultMode },
    camera: struct { core: Core, spec: []const u8 },
    skip_bkpt: struct { core: Core },
    load: struct { core: Core, image: []const u8 },
};

/// Details of a past intervention waiting for user confirmation before creating a branch.
pub const PendingFork = struct {
    reason: ForkReason,
    position: Position,
    action: Action,
};

/// The routing decision made by the choke point.
pub const RouteDecision = enum {
    live,
    needs_confirmation,
    fork,
};

/// Duplicates any borrowed slice in `action` using `allocator`.
pub fn dupeAction(allocator: std.mem.Allocator, action: Action) !Action {
    switch (action) {
        .memory => |m| return .{ .memory = .{ .core = m.core, .address = m.address, .bytes = try allocator.dupe(u8, m.bytes) } },
        .console => |c| return .{ .console = .{ .core = c.core, .bytes = try allocator.dupe(u8, c.bytes) } },
        .camera => |cam| return .{ .camera = .{ .core = cam.core, .spec = try allocator.dupe(u8, cam.spec) } },
        .plug => |p| return .{ .plug = .{ .core = p.core, .at = p.at, .name = if (p.name) |n| try allocator.dupe(u8, n) else null } },
        .load => |l| return .{ .load = .{ .core = l.core, .image = try allocator.dupe(u8, l.image) } },
        else => return action,
    }
}

/// Frees any duplicated slice in `action` using `allocator`.
pub fn freeAction(allocator: std.mem.Allocator, action: *Action) void {
    switch (action.*) {
        .memory => |m| allocator.free(m.bytes),
        .console => |c| allocator.free(c.bytes),
        .camera => |cam| allocator.free(cam.spec),
        .plug => |p| if (p.name) |n| allocator.free(n),
        .load => |l| allocator.free(l.image),
        else => {},
    }
}

/// Pure decision function: evaluates whether an intervention is live, needs confirmation, or forks.
pub fn decide(
    graph: ?*const BranchGraph,
    active_line: BranchId,
    cursor: Position,
    recorded_end: Position,
    confirmed: bool,
    reason: ForkReason,
) RouteDecision {
    _ = reason;
    const g = graph orelse return .live;
    const ord = g.compareOnLine(active_line, cursor, recorded_end) catch return .live;
    if (ord != .lt) {
        return .live;
    }
    if (!confirmed) {
        return .needs_confirmation;
    }
    return .fork;
}

/// Router state holding confirmation status, pending fork, and sequence counter.
pub const ForkRouter = struct {
    allocator: std.mem.Allocator,
    graph: ?*BranchGraph = null,
    active_line: BranchId = branch_mod.root_branch_id,
    first_fork_confirmed: bool = false,
    pending_fork: ?PendingFork = null,
    seq: u32 = 0,

    /// Initializes a fork router optionally bound to a branch graph.
    pub fn init(allocator: std.mem.Allocator, graph: ?*BranchGraph) ForkRouter {
        return .{
            .allocator = allocator,
            .graph = graph,
            .active_line = if (graph) |g| g.active_branch else branch_mod.root_branch_id,
        };
    }

    pub fn deinit(self: *ForkRouter) void {
        self.cancel();
    }

    /// Switches the active line to a different branch.
    pub fn switchActiveLine(self: *ForkRouter, new_line: BranchId) void {
        self.active_line = new_line;
        if (self.graph) |g| {
            g.active_branch = new_line;
        }
    }

    /// Returns the recorded end position of the active execution line.
    pub fn recordedEnd(self: *const ForkRouter) Position {
        if (self.graph) |g| {
            if (g.get(self.active_line)) |node| {
                return node.recorded_end;
            }
        }
        return .{
            .branch = self.active_line,
            .r = 0,
            .phase = .cpu0,
            .o = 0,
            .gap = .retired,
        };
    }

    /// Advances and returns the next monotonic sequence number for history events.
    pub fn nextSeq(self: *ForkRouter) u32 {
        const s = self.seq;
        self.seq += 1;
        return s;
    }

    /// Stores details of an unconfirmed fork, owning any byte payloads.
    pub fn setPending(self: *ForkRouter, reason: ForkReason, pos: Position, action: Action) !void {
        self.cancel();
        const owned = try dupeAction(self.allocator, action);
        self.pending_fork = .{
            .reason = reason,
            .position = pos,
            .action = owned,
        };
    }

    /// Pops the pending fork, giving ownership of the allocated action to the caller.
    pub fn popPending(self: *ForkRouter) ?PendingFork {
        const pending = self.pending_fork orelse return null;
        self.pending_fork = null;
        return pending;
    }

    /// Discards any pending fork request without mutating state, freeing owned bytes.
    pub fn cancel(self: *ForkRouter) void {
        if (self.pending_fork) |*pending| {
            freeAction(self.allocator, &pending.action);
            self.pending_fork = null;
        }
    }
};
