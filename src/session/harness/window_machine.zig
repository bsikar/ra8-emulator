//! The machine the reverse window drives in a real session (section 2.5):
//! the window port over the harness's live session and its save files.
//!
//! A replayed slot is a one-instruction run with the session muted, so
//! nothing it passes is recorded again. The live run's own slot is the
//! session's run, unmuted, so checkpoints, landings and interventions
//! record as they do for any live run; the window driver (window.zig)
//! feeds it the command and reads back how the slot ended.
const std = @import("std");
const api = @import("../api.zig");
const line = @import("../line.zig");
const state = @import("../board/state.zig");
const port_mod = @import("../history/window_port.zig");

const Position = port_mod.Position;
const Core = port_mod.Core;

pub const Machine = struct {
    session: *api.Session,
    files: *state.Files,
    /// A replayed slot is in flight: the window's own walk, not the run.
    muted: bool = false,
    /// The live run's command, for the first slot of a run; later slots
    /// carry on with the stop machine as it stands.
    command: api.Run = .cont,
    first: bool = true,
    /// How the last live slot ended, and whether it ran at all.
    ended: api.Ended = .count,
    ran: bool = false,

    pub fn port(self: *Machine) port_mod.Port {
        return .{ .context = self, .vtable = &vtable };
    }

    /// The position the run stands at, on the line it runs on. A machine
    /// that has not run yet stands at its boundary's own saved round.
    pub fn position(self: *const Machine) Position {
        const session = self.session;
        var at = line.currentPosition(session);
        if (session.grid != null) return at;
        const edge = session.live.boundary orelse return at;
        const branch = at.branch;
        at = (edge.saved orelse &session.live.saved).at;
        at.branch = branch;
        return at;
    }

    /// Starts a live run: its first slot arms `command`.
    pub fn begin(self: *Machine, command: api.Run) void {
        self.command = command;
        self.first = true;
    }

    /// Runs the live run on from where it stands, unrecorded: the first
    /// call arms the command, later ones carry on.
    pub fn raw(self: *Machine) !api.Ended {
        const live = &self.session.live;
        const ended = if (self.first) try live.go(self.command) else try live.goOn();
        self.first = false;
        self.ran = true;
        self.ended = ended;
        return ended;
    }

    /// The core a slot taken now runs on: the one whose phase it is.
    pub fn coreAt(self: *const Machine) Core {
        return if (self.position().phase == .cpu1) .cpu1 else .cpu0;
    }

    pub fn cpuOf(self: *const Machine, core: Core) ?*port_mod.Cpu {
        return switch (core) {
            .cpu0 => self.files.cpu,
            .cpu1 => if (self.files.pair) |pair| &pair.core.cpu else null,
        };
    }

    const vtable: port_mod.Port.VTable = .{
        .position = vPosition,
        .line = vLine,
        .cpu = vCpu,
        .step = vStep,
        .saveFull = saveFull,
        .restoreFull = restoreFull,
        .saveSide = saveSide,
        .loadSide = loadSide,
        .liveStep = liveStep,
    };

    fn of(context: *anyopaque) *Machine {
        return @ptrCast(@alignCast(context));
    }

    fn vPosition(context: *anyopaque) Position {
        return of(context).position();
    }

    fn vLine(context: *anyopaque) u32 {
        return of(context).position().branch;
    }

    fn vCpu(context: *anyopaque, core: Core) ?*port_mod.Cpu {
        return of(context).cpuOf(core);
    }

    /// One replayed slot: a one-instruction run, muted, on the core's turn.
    fn vStep(context: *anyopaque, core: Core) anyerror!void {
        const self = of(context);
        const session = self.session;
        const asked: api.Core = if (core == .cpu0) .cpu0 else .cpu1;
        const selected = session.currentCore();
        const prior = budgetOf(session, asked);
        const was_replaying = session.replaying;
        const was_muted = self.muted;
        session.setReplaying(true);
        self.muted = true;
        defer {
            self.muted = was_muted;
            session.setReplaying(was_replaying);
            session.setRunBudget(asked, prior) catch {};
            session.select(selected) catch {};
        }
        try session.setRunBudget(asked, 1);
        const ended = try session.run(asked, .cont);
        if (ended != .count) return error.UnexpectedStop;
    }

    /// One live slot: the session's own run, one instruction, or the one
    /// canonical stop a step asks for.
    fn liveStep(context: *anyopaque, core: Core) anyerror!void {
        _ = core;
        const self = of(context);
        const before = self.position();
        const ended = try self.raw();
        if (ended != .count and std.meta.eql(before, self.position())) return port_mod.StepError.NoSlot;
    }

    fn saveFull(context: *anyopaque, writer: *std.Io.Writer) anyerror!void {
        try of(context).files.writeTo(writer);
    }

    /// The window's own restore: the whole save stream, without telling the
    /// session to forget its window.
    fn restoreFull(context: *anyopaque, bytes: []const u8) anyerror!void {
        try of(context).files.readParts(bytes, .{});
    }

    fn saveSide(context: *anyopaque, writer: *std.Io.Writer) anyerror!void {
        try of(context).files.writeParts(writer, .{ .memory = false });
    }

    fn loadSide(context: *anyopaque, bytes: []const u8, board: bool) anyerror!void {
        try of(context).files.readParts(bytes, .{ .memory = false, .board = board });
    }
};

/// The run budget `core` holds now, whether it has the session or is parked.
fn budgetOf(session: *const api.Session, core: api.Core) u64 {
    const live = &session.live;
    if (live.index == @backingInt(core)) return live.budget;
    return if (live.other) |parked| parked.budget else live.budget;
}
