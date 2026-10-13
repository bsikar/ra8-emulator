//! The shell's locals leaf (RA8EMU-805): one core's locals at the stopped
//! pc asked over the session link (locals 0x0129) into the locals pane's
//! (RA8EMU-805) Snapshot, so the pane draws in the shell unchanged. The
//! session reads the image's .debug_info and packs each local with its
//! type, size, and where it lives; the leaf only copies the answer. One
//! ask goes out once the image has loaded and after every stop of the
//! leaf's core; a load starts over.
const std = @import("std");
const rpc = @import("ra8_rpc");
const proto = rpc.session.rpc;
const locals_wire = rpc.locals_wire;
const session_link = @import("../session_link.zig");
const locals_pane = @import("../ui/locals_pane.zig");
const pane_layout = @import("../ui/pane_layout.zig");

const Env = proto.Client.Env;
pub const Snapshot = locals_pane.Snapshot;

comptime {
    std.debug.assert(locals_pane.max_rows == proto.locals_rows);
    std.debug.assert(locals_pane.name_cap == proto.local_name_cap);
    std.debug.assert(locals_pane.type_cap == proto.local_type_cap);
}

pub const Locals = struct {
    core: proto.Core,
    /// An ask is due on the next attach.
    want: bool = false,
    /// The id of the ask in flight.
    asked: ?u32 = null,
    now: ?Snapshot = null,
    refused: bool = false,
    /// A load landed while an ask was in flight: its answer describes the
    /// old image, so it publishes nothing and a fresh ask follows it.
    stale: bool = false,

    /// Send the due ask unless one is in flight or the session has not
    /// greeted.
    pub fn attach(self: *Locals, link: *session_link.Link) void {
        if (link.state != .connected or !self.want or self.asked != null) return;
        const args: proto.CoreOnly = .{ .core = self.core };
        self.asked = link.send(proto.CoreOnly, .locals, args) catch |err| switch (err) {
            error.TableFull => return,
            else => null,
        };
        self.want = false;
        if (self.asked == null) self.refused = true;
    }

    /// A stop of this core makes an ask due; the answer to the one in
    /// flight becomes the shown rows. Everything else is ignored.
    pub fn observe(self: *Locals, arrival: session_link.Arrival) void {
        switch (arrival) {
            .event => |event| self.stopped(event),
            .response => |response| self.answered(response.id, response.result),
        }
    }

    /// A new image: ask again and show nothing of the old one.
    pub fn reload(self: *Locals) void {
        self.want = true;
        self.stale = self.asked != null;
        self.now = null;
    }

    /// The leaf's note while it has no rows to draw, or null.
    pub fn note(self: *const Locals) ?[]const u8 {
        if (self.refused) return "the session would not read the locals";
        if (self.now == null) return "waiting for the locals";
        return null;
    }

    fn stopped(self: *Locals, event: Env.Event) void {
        if (event.topic != @backingInt(proto.Topic.stop)) return;
        const stop = proto.decode(proto.Stopped, event.payload) catch return;
        if (stop.core == self.core) self.want = true;
    }

    fn answered(self: *Locals, id: u32, result: Env.Result) void {
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
        const list = proto.decode(proto.Locals, body) catch return self.refuse();
        self.now = unpack(list) catch return self.refuse();
        self.refused = false;
    }

    /// A refused ask keeps the last rows with the note.
    fn refuse(self: *Locals) void {
        self.refused = true;
    }
};

/// The pane's snapshot of `list`: names and types copied, so the snapshot
/// holds no slice into the link's buffer.
pub fn unpack(list: proto.Locals) !Snapshot {
    var snapshot: Snapshot = .{};
    var reader: locals_wire.Reader = .{ .rest = list.rows };
    while (try reader.next()) |found| {
        if (snapshot.count == locals_pane.max_rows) return error.Oversize;
        const row = &snapshot.rows[snapshot.count];
        row.* = .{ .size = found.size, .where_kind = found.where_kind, .where_a = @bitCast(found.where_a), .where_b = @bitCast(found.where_b) };
        row.name_len = found.name.len;
        @memcpy(row.name_buf[0..found.name.len], found.name);
        row.type_len = found.type_name.len;
        @memcpy(row.type_buf[0..found.type_name.len], found.type_name);
        snapshot.count += 1;
    }
    if (snapshot.count != @as(usize, list.count)) return error.Truncated;
    return snapshot;
}

/// One model per core, so each leaf shows the core it is bound to.
pub const Pair = struct {
    cores: [2]Locals = .{ .{ .core = .cpu0 }, .{ .core = .cpu1 } },

    pub fn of(self: *const Pair, core: pane_layout.Core) *const Locals {
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
