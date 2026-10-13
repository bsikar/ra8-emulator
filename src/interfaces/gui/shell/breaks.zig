//! The run-to point on the shell's disassembly leaves (RA8EMU-1171): a
//! click on a line asks the session for a breakpoint on that address, so
//! the next resume runs to it, and a click on a line that already holds
//! one asks to clear it. The marks follow the session: the set answer and
//! the session's breakpoint_set event add a mark, a cleared answer drops
//! it. A breakpoint the session reports but this shell never asked for
//! (one placed over gdb or the CLI) has no id on file, so its line's
//! click is left alone.
const std = @import("std");
const proto = @import("ra8_rpc").session.rpc;
const session_link = @import("../session_link.zig");
const shell_frame = @import("../ui/shell/frame.zig");
const shell_memory = @import("memory.zig");
const disasm_pane = @import("../ui/disasm_pane.zig");
const pane_layout = @import("../ui/pane_layout.zig");
const shell_panes = @import("panes.zig");

const geom = @import("../geom.zig");
const Rect = geom.Rect;
const Env = proto.Client.Env;

/// Breakpoints one core's leaf tracks at once.
pub const cap: usize = 16;

pub const Flight = enum { none, set, clear };

/// One core's run-to points: the session's ids and their addresses.
pub const Core = struct {
    ids: [cap]u32 = @splat(0),
    at: [cap]u32 = @splat(0),
    left: usize = 0,
    /// The ask in flight: its ask id (null when none), what it was for,
    /// and the id or address it carries.
    flight: ?u32 = null,
    kind: Flight = .none,
    want: u32 = 0,
    /// A click made while the ask was in flight, to send after it.
    queued: ?u32 = null,

    fn add(self: *Core, id: u32, address: u32) void {
        for (self.at[0..self.left], 0..) |at, i| if (at == address) {
            self.ids[i] = id;
            return;
        };
        if (self.left == cap) return;
        self.ids[self.left] = id;
        self.at[self.left] = address;
        self.left += 1;
    }

    fn drop(self: *Core, id: u32) void {
        for (self.ids[0..self.left], 0..) |held, i| if (held == id) {
            self.left -= 1;
            self.ids[i] = self.ids[self.left];
            self.at[i] = self.at[self.left];
            self.ids[self.left] = 0;
            self.at[self.left] = 0;
            return;
        };
    }

    fn lineOf(self: *const Core, address: u32) ?usize {
        for (self.at[0..self.left], 0..) |at, i| if (at == address) return i;
        return null;
    }
};

/// One model per core, so each leaf toggles the core it is bound to.
pub const Breaks = struct {
    cores: [2]Core = .{ .{}, .{} },

    /// Drops every mark and ask in flight: the session was rebuilt and
    /// its breakpoint ids are gone (RA8EMU-1152).
    pub fn reset(self: *Breaks) void {
        self.cores = .{ .{}, .{} };
    }

    /// The addresses marked on `core`'s pane, oldest first.
    pub fn marks(self: *const Breaks, core: pane_layout.Core) []const u32 {
        const model = &self.cores[@backingInt(core)];
        return model.at[0..model.left];
    }

    /// Route a left press at (`x`, `y`) to a disassembly leaf's line: the
    /// run-to point toggles there. Returns whether a line was hit.
    pub fn clickIn(self: *Breaks, link: *session_link.Link, code: *const shell_memory.Pair, layout: *const pane_layout.Layout, solved: *const pane_layout.Solved, x: i32, y: i32) bool {
        for (solved.panes.items) |placed| {
            const pane = layout.pane(placed.index) orelse continue;
            if (pane.kind != .disasm) continue;
            const body = shell_frame.toGeom(shell_frame.bodyOf(placed.area));
            if (!geom.contains(body, x, y)) continue;
            const model = code.of(pane.core);
            const read = if (model.now) |*snap| snap else continue;
            const row = rowAt(body, x, y) orelse continue;
            const lines = shell_panes.codeSnapshotFrom(model.from, read, body);
            if (row >= lines.count) return false;
            return self.toggle(link, model.core, lines.lines[row].address);
        }
        return false;
    }

    /// Toggle the run-to point on `core`'s `address`: a line that holds
    /// one with an id on file asks to clear it, an empty line asks to set
    /// one, and a mark with no id on file (placed elsewhere) stays. A
    /// click while an ask is in flight is held for after it answers.
    pub fn toggle(self: *Breaks, link: *session_link.Link, core: proto.Core, address: u32) bool {
        const model = self.modelOf(core);
        if (model.flight != null) {
            if (model.queued == null) model.queued = address;
            return true;
        }
        if (model.lineOf(address)) |i| {
            const id = model.ids[i];
            if (id == 0) return true;
            const asked = link.send(proto.PointId, .clear_breakpoint, .{ .core = core, .id = id }) catch return false;
            model.kind = .clear;
            model.want = id;
            model.flight = asked;
            return true;
        }
        const asked = link.send(proto.Point, .set_breakpoint, .{ .core = core, .address = address }) catch return false;
        model.kind = .set;
        model.want = address;
        model.flight = asked;
        return true;
    }

    /// Send a click held while an ask was in flight.
    pub fn attach(self: *Breaks, link: *session_link.Link) void {
        if (link.state != .connected) return;
        for (&self.cores, [_]proto.Core{ .cpu0, .cpu1 }) |*model, core| {
            const address = model.queued orelse continue;
            if (model.flight != null) continue;
            model.queued = null;
            _ = self.toggle(link, core, address);
        }
    }

    /// A set or clear answer moves the marks; everything else is ignored.
    pub fn observe(self: *Breaks, arrival: session_link.Arrival) void {
        switch (arrival) {
            .event => |ev| self.event(ev),
            .response => |response| self.answered(response.id, response.result),
        }
    }

    fn modelOf(self: *Breaks, core: proto.Core) *Core {
        return &self.cores[@backingInt(core)];
    }

    fn event(self: *Breaks, arrival: Env.Event) void {
        if (arrival.topic != @backingInt(proto.Topic.session)) return;
        const session = proto.decode(proto.SessionEvent, arrival.payload) catch return;
        switch (session.kind) {
            .breakpoint_set => self.modelOf(session.core).add(0, session.address),
            else => {},
        }
    }

    fn answered(self: *Breaks, id: u32, result: Env.Result) void {
        for (&self.cores) |*model| {
            const flight = model.flight orelse continue;
            if (flight != id) continue;
            model.flight = null;
            const kind = model.kind;
            const want = model.want;
            model.kind = .none;
            model.want = 0;
            switch (result) {
                .ok => |body| switch (kind) {
                    .set => {
                        const placed = proto.decode(proto.U32, body) catch return;
                        model.add(placed.value, want);
                    },
                    .clear => model.drop(want),
                    .none => {},
                },
                .err => {},
            }
            return;
        }
    }
};

/// The line row whose band holds (`x`, `y`) inside `body`, or null.
pub fn rowAt(body: Rect, x: i32, y: i32) ?usize {
    if (!geom.contains(body, x, y)) return null;
    const row: usize = @intCast(@divTrunc(y - body.y - disasm_pane.pad, disasm_pane.row_h));
    return row;
}
