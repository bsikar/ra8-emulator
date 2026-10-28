//! The replay that indexes a late-armed marker: restore the history's
//! earliest checkpoint on the active line, replay forward to the line's
//! recorded end with a breakpoint on the marker's address, and keep the
//! position of every arrival in order. The machine is left wherever the
//! scan ended, so a caller returns it to where it stood with `returnTo`.
//!
//! Nothing here records: the whole walk runs replaying, so no checkpoint,
//! landing or intervention is written for a position the log already holds.

const std = @import("std");
const api = @import("../api.zig");
const command_mod = @import("command.zig");
const line = @import("../line.zig");
const position_mod = @import("../history/position.zig");
const seek_engine = @import("../history/seek_engine.zig");
const transport_mod = @import("transport.zig");

const Transport = transport_mod.Transport;
const Position = position_mod.Position;

pub const Error = error{ NoCheckpoint, ScanFault, Stalled, TooManyArrivals };

/// The most arrivals one scan keeps; a marker on a hot address past this
/// is refused rather than indexed in part.
pub const max_arrivals: usize = 1 << 20;

/// Replays the recorded history and appends the position of every arrival
/// at `address`, in order. A cursor that never ran has nothing recorded to
/// replay and answers no arrivals.
pub fn scan(
    self: *Transport,
    allocator: std.mem.Allocator,
    address: u32,
    out: *std.ArrayListUnmanaged(Position),
) !void {
    const bridge = self.history orelse return command_mod.Error.NotReady;
    const session = self.session;
    if (session.grid == null) return;
    var facts = bridge.facts(bridge.context) catch return command_mod.Error.HistoryBroken;
    if (session.fork_router) |router| {
        facts.graph = router.graph;
        facts.active_line = router.active_line;
    }
    const base = earliest(session, facts) orelse return Error.NoCheckpoint;
    const core = session.currentCore();
    const prior = transport_mod.budgetOf(session, core);
    self.cancel();
    self.epoch += 1;
    defer session.setRunBudget(core, prior) catch {};
    try self.restoreBase(base);
    session.setReplaying(true);
    defer session.setReplaying(false);
    const id = try session.setBreakpoint(core, .{ .address = address });
    defer session.clearBreakpoint(core, id) catch {};
    try walk(session, core, address, id, allocator, out);
}

/// The checkpoint with the earliest position on the active line.
fn earliest(session: *api.Session, facts: seek_engine.Facts) ?seek_engine.Base {
    var best: ?seek_engine.Checkpoint = null;
    for (facts.checkpoints) |c| {
        if (best) |held| {
            const order = session.comparePositions(c.position, held.position) catch continue;
            if (order != .lt) continue;
        } else {
            _ = session.comparePositions(c.position, c.position) catch continue;
        }
        best = c;
    }
    const found = best orelse return null;
    return .{ .checkpoint = .{ .id = found.id, .object = found.object, .position = found.position } };
}

fn walk(
    session: *api.Session,
    core: api.Core,
    address: u32,
    id: api.BreakId,
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(Position),
) !void {
    const router = session.fork_router orelse return command_mod.Error.NotReady;
    // A base that itself sits on the address is an arrival at the base's
    // position: the first resume executes through it.
    if (sitsOn(session, core, address)) try note(session, allocator, out);
    var stalled: u8 = 0;
    while (line.inPast(session)) {
        const before = line.currentPosition(session);
        const ended = try session.run(core, .cont);
        switch (ended) {
            .count => {},
            .core => return Error.ScanFault,
            .stop => |stop| switch (stop) {
                .breakpoint => |hit| if (hit == id) {
                    const order = session.comparePositions(line.currentPosition(session), router.recordedEnd()) catch .gt;
                    if (order != .gt) try note(session, allocator, out);
                },
                else => {},
            },
        }
        const moved = position_mod.compare(before, line.currentPosition(session)) catch .lt;
        stalled = if (moved == .eq) stalled + 1 else 0;
        if (stalled > 2) return Error.Stalled;
    }
}

fn note(session: *api.Session, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(Position)) !void {
    const here = line.currentPosition(session);
    if (out.items.len > 0) {
        const last = out.items[out.items.len - 1];
        if ((position_mod.compare(last, here) catch .lt) == .eq) return;
    }
    if (out.items.len >= max_arrivals) return Error.TooManyArrivals;
    try out.append(allocator, here);
}

fn sitsOn(session: *api.Session, core: api.Core, address: u32) bool {
    const pc = session.register(core, .pc) catch return false;
    return (pc & ~@as(u32, 1)) == (address & ~@as(u32, 1));
}

/// Puts the machine back at `origin` by a blocking seek, as the front end
/// that asked for the scan stood before it.
pub fn returnTo(self: *Transport, origin: Position, wall: command_mod.Wall) !void {
    var buf: [96]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{d}:{d}:{s}:{d}:{s}", .{
        origin.branch,
        origin.r,
        @tagName(origin.phase),
        origin.o,
        @tagName(origin.gap),
    });
    const ticket = try self.command(.{ .seek = .{ .target = text } });
    _ = try self.finish(ticket, wall, null);
}
