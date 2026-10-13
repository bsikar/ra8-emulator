//! The shell's source leaf (RA8EMU-1125): one core's source place asked
//! over the session link (source line 0x0128) into the source pane's
//! (RA8EMU-745) Snapshot. The session answers the file and line the pc
//! belongs to; the leaf reads the file's rows itself, from the shell's
//! working directory, the current line in the middle. One ask goes out
//! once the image has loaded and after every stop of the leaf's core; a
//! load starts over.
const std = @import("std");
const rpc = @import("ra8_rpc");
const proto = rpc.session.rpc;
const session_link = @import("../session_link.zig");
const source_capture = @import("../source_capture.zig");
const source_pane = @import("../ui/source_pane.zig");
const pane_layout = @import("../ui/pane_layout.zig");

const Env = proto.Client.Env;
pub const Snapshot = source_pane.Snapshot;

/// Rows one ask reads: enough to fill a tall pane, an odd count so the
/// current line keeps a neighbour below.
pub const row_count: usize = 31;

pub const Source = struct {
    core: proto.Core,
    io: std.Io,
    /// An ask is due on the next attach.
    want: bool = false,
    /// The id of the ask in flight.
    asked: ?u32 = null,
    now: ?Snapshot = null,
    refused: bool = false,
    /// A load landed while an ask was in flight: its answer describes the
    /// old image, so it publishes nothing and a fresh ask follows it.
    stale: bool = false,
    /// The lines this leaf's pane set; a source pane in the shell cannot
    /// reach the session's breakpoints yet (RA8EMU-765).
    marks: source_pane.Marks = .{},

    /// Send the due ask unless one is in flight or the session has not
    /// greeted.
    pub fn attach(self: *Source, link: *session_link.Link) void {
        if (link.state != .connected or !self.want or self.asked != null) return;
        const args: proto.CoreOnly = .{ .core = self.core };
        self.asked = link.send(proto.CoreOnly, .source_line, args) catch |err| switch (err) {
            error.TableFull => return,
            else => null,
        };
        self.want = false;
        if (self.asked == null) self.refused = true;
    }

    /// A stop of this core makes an ask due; the answer to the one in
    /// flight becomes the shown lines. Everything else is ignored.
    pub fn observe(self: *Source, arrival: session_link.Arrival) void {
        switch (arrival) {
            .event => |event| self.stopped(event),
            .response => |response| self.answered(response.id, response.result),
        }
    }

    /// A new image: ask again and show nothing of the old one.
    pub fn reload(self: *Source) void {
        self.want = true;
        self.stale = self.asked != null;
        self.now = null;
    }

    /// The leaf's note while it has no lines to draw, or null.
    pub fn note(self: *const Source) ?[]const u8 {
        if (self.refused) return "the session would not name the source place";
        if (self.now == null) return "waiting for the source line";
        return null;
    }

    fn stopped(self: *Source, event: Env.Event) void {
        if (event.topic != @backingInt(proto.Topic.stop)) return;
        const stop = proto.decode(proto.Stopped, event.payload) catch return;
        if (stop.core == self.core) self.want = true;
    }

    fn answered(self: *Source, id: u32, result: Env.Result) void {
        if (self.asked != id) return;
        self.asked = null;
        if (self.stale) {
            self.stale = false;
            return;
        }
        const body = switch (result) {
            .ok => |bytes| bytes,
            .err => return self.refuse(),
        };
        const place = proto.decode(proto.SourceLine, body) catch return self.refuse();
        if (place.found == 0) {
            self.now = .{ .pc = place.pc };
            self.refused = false;
            return;
        }
        self.now = source_capture.captureRows(place.pc, place.line, place.path, self.io, std.Io.Dir.cwd(), row_count) catch return self.refuse();
        self.refused = false;
    }

    /// A refused ask keeps the last lines with the note.
    fn refuse(self: *Source) void {
        self.refused = true;
    }
};

/// One model per core, so each leaf shows the core it is bound to.
pub const Pair = struct {
    cores: [2]Source,

    pub fn init(io: std.Io) Pair {
        return .{ .cores = .{ .{ .core = .cpu0, .io = io }, .{ .core = .cpu1, .io = io } } };
    }

    pub fn of(self: *Pair, core: pane_layout.Core) *Source {
        return &self.cores[@backingInt(core)];
    }

    pub fn attach(self: *Pair, link: *session_link.Link) void {
        for (&self.cores) |*model| model.attach(link);
    }

    pub fn observe(self: *Pair, arrival: session_link.Arrival) void {
        for (&self.cores) |*model| model.observe(arrival);
    }

    pub fn reload(self: *Pair) void {
        for (&self.cores) |*model| model.reload();
    }

    /// The cores halted with no stop event of their own, as a paused run
    /// does (shell_run.zig): walk them again.
    pub fn refresh(self: *Pair) void {
        for (&self.cores) |*model| model.want = true;
    }
};
