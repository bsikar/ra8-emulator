//! One Session run slice over the recorded history (time-travel design
//! sections 2.1 and 11): forward play inside the recorded past is replay,
//! past the line's recorded end it is live recording, with no seam.
//!
//! A slice that starts before the recorded end runs replaying, so nothing
//! it passes is recorded again (no checkpoint, landing, stop frame or
//! intervention), and the recorded interventions of the line are
//! re-applied as the run reaches them. A slice that crosses the end
//! records again from the next slice on.
const std = @import("std");
const api = @import("api.zig");
const line = @import("line.zig");
const async_traffic = @import("history/async_traffic.zig");

const Session = api.Session;
const Core = api.Core;

pub fn run(self: *Session, core: Core, command: api.Run) anyerror!api.Ended {
    return drive(self, core, command);
}

/// Continue a budget-limited command without rearming its step or resume grace.
pub fn continueRun(self: *Session, core: Core) anyerror!api.Ended {
    // Window drivers own their instruction recording and have no continuation hook.
    if (self.window_driver != null) return error.UnsupportedContinuation;
    if ((try self.machine(core)).mode == .halted) return error.NotRunning;
    return drive(self, core, null);
}

fn drive(self: *Session, core: Core, command: ?api.Run) anyerror!api.Ended {
    try self.select(core);
    self.grid = if (self.live.boundary) |edge| edge.saved orelse &self.live.saved else null;
    line.stampLine(self);
    try deliverDue(self);
    if (self.window_driver) |driver| driver.enterFn(driver.context, self);
    const replay = !self.replaying and line.inPast(self);
    if (replay) self.setReplaying(true);
    defer if (replay) self.setReplaying(false);
    const budget = self.live.budget;
    defer self.live.budget = budget;
    clampToNextItem(self);
    const retired_before = self.live.core.cpu.retired;
    const ended = if (command) |cmd| blk: {
        break :blk if (self.window_driver) |driver| try driver.goFn(driver.context, self, cmd) else try self.live.go(cmd);
    } else try self.live.goOn();
    if (self.live.boundary == null) try advanceBoard(self, core, self.live.core.cpu.retired - retired_before);
    line.notePosition(self, line.currentPosition(self));
    if (self.window_driver) |driver| driver.settleFn(driver.context, self);
    try deliverDue(self);
    if (self.replaying) {
        if (self.replay_feeder) |*feeder| feeder.checkMissed(self);
    }
    const stopped: Core = @fromBackingInt(@intCast(self.live.ended_index));
    self.publish(.{ .core = stopped, .kind = .stopped, .ended = ended });
    if (self.history) |h| if ((command != null and command != .cont) or !endedOnBudget(ended)) try recordStop(self, h, core, stopped, ended);
    if (ended == .core) {
        const address: ?u32 = switch (ended.core) {
            .count => null,
            .unknown => |instruction| instruction.address,
            inline else => |at| at,
        };
        self.publish(.{ .core = stopped, .kind = .fault, .address = address, .payload = .{ .fault = .{ .cause = @backingInt(std.meta.activeTag(ended.core)), .address = address } } });
    }
    // Queued host traffic reaches the machine once the run is back at the
    // recorded end; the stop above is already published and captured, so
    // a delivery that fails reports on a run whose state is settled.
    _ = try async_traffic.drainIfNeeded(self);
    // A recorded source that could not serve the replay stops the run: what
    // the guest saw instead is not the recorded past.
    if (self.replay_failure) |failure| {
        self.replay_failure = null;
        return .{ .stop = .{ .replay_failed = failure } };
    }
    return ended;
}

/// Advances one replay slot on whichever core owns the current round phase,
/// delivering any recorded interventions due before or after the slot.
pub fn stepReplaySlot(self: *Session) anyerror!api.Ended {
    self.grid = if (self.live.boundary) |edge| edge.saved orelse &self.live.saved else null;
    line.stampLine(self);
    try deliverDue(self);
    if (self.live.started) self.live.machine.proceed() else self.live.machine.begin();
    const res = try self.live.stepSlot(std.math.maxInt(u64), null);
    line.notePosition(self, line.currentPosition(self));
    try deliverDue(self);
    if (self.replay_failure) |failure| {
        self.replay_failure = null;
        return .{ .stop = .{ .replay_failed = failure } };
    }
    return res.ended;
}

/// Re-applies the recorded interventions due at the session's position.
pub fn deliverDue(self: *Session) anyerror!void {
    if (self.replay_feeder) |*feeder| try feeder.checkAndApply(self);
}

/// Shortens the slice so the run stops on the next recorded intervention
/// when it lies ahead in the phase the run is in; one in a later phase or
/// round is delivered at the first check at or past it.
fn clampToNextItem(self: *Session) void {
    const feeder = if (self.replay_feeder) |*f| f else return;
    const next = feeder.nextPosition() orelse return;
    const at = line.currentPosition(self);
    if (at.r != next.r or at.phase != next.phase or next.o <= at.o) return;
    const dist = next.o - at.o;
    if (self.live.budget > dist) self.live.budget = dist;
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

fn endedOnBudget(ended: api.Ended) bool {
    return switch (ended) {
        .count => true,
        .core => |c| c == .count,
        else => false,
    };
}
