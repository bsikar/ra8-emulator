//! The slice-click's rewind (RA8EMU-838): the shell's shared time cursor
//! plus the session snapshot ring it rewinds from. A click on a timeline
//! slice moves the cursor to the slice's start and rewinds the run there:
//! the newest session snapshot at or before that moment, then a
//! virtual-time advance over the difference. With nothing kept this far
//! back the run stays live and the pane says so.

const std = @import("std");
const proto = @import("ra8_rpc").session.rpc;
const draw_list = @import("ra8_render").draw_list;
const pane_layout = @import("../ui/pane_layout.zig");
const timeline_model = @import("../timeline_model.zig");
const timeline_pane = @import("../timeline_pane.zig");
const cursor_mod = @import("../time_cursor.zig");
const ring_mod = @import("../snapshot_ring.zig");
const session_link = @import("../session_link.zig");
const shell_frame = @import("../ui/shell/frame.zig");
const status_bar = @import("../status/bar.zig");

const Link = session_link.Link;

/// Where the ring's files go, on the serving host.
pub const snap_dir = "/tmp/ra8-snaps";

/// Beside the link this often of board time while the record moves.
pub const stamp_interval_ns: u64 = 10 * std.time.ns_per_ms;

/// One frame of a rewind in flight: restore, then advance.
pub const Step = enum { none, restoring, advancing };

/// The shell owns one of these. The ring must not move once it has taken
/// a snapshot, so the shell is built in place before any is.
pub const Snapshots = struct {
    cursor: cursor_mod.Cursor = .{},
    ring: ring_mod.Ring,
    step: Step = .none,
    /// The moment the rewind is going to.
    going_ns: u64 = 0,
    /// The snapshot being restored, when one is.
    entry_ns: u64 = 0,
    /// The requests in flight, matched by pump.
    snapshot_id: u32 = 0,
    restore_id: u32 = 0,
    advance_id: u32 = 0,
    /// The advance is on the wire.
    advance_sent: bool = false,
    /// Board time a snapshot beside the link is this often stamped at.
    stamped_ns: u64 = 0,
    /// The snapshot in flight, written when its answer lands.
    pending_ns: u64 = 0,
    pending_path: ?[]const u8 = null,
    /// The click's note, when the ring has nothing this far back.
    notice: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) Snapshots {
        return .{ .ring = ring_mod.Ring.init(allocator) };
    }
    pub fn deinit(self: *Snapshots) void {
        self.ring.deinit();
    }

    /// A left press on a timeline slice: move the cursor to the slice's
    /// start and start the rewind there. Returns whether the press was
    /// taken.
    pub fn pressed(self: *Snapshots, link: *Link, layout: *const pane_layout.Layout, solved: *const pane_layout.Solved, model: ?*timeline_model.Model, x: i32, y: i32) bool {
        const found = model orelse return false;
        for (solved.panes.items) |placed| {
            const pane = layout.pane(placed.index) orelse continue;
            if (pane.kind != .timeline) continue;
            const hit = timeline_pane.hitAt(shell_frame.bodyOf(placed.area), found, self.view(found, placed.area), x, y) orelse return false;
            self.startRewind(link, hit.start_ns);
            return true;
        }
        return false;
    }

    /// Start the rewind to `ns`: the newest snapshot this far back, then
    /// the advance over the difference. Nothing kept means live.
    pub fn startRewind(self: *Snapshots, link: *Link, ns: u64) void {
        self.cursor.moveTo(ns);
        self.notice = null;
        const entry = self.ring.atOrBefore(ns) orelse {
            self.notice = "state not kept this far back";
            return;
        };
        self.step = .restoring;
        self.going_ns = ns;
        self.entry_ns = entry.ns;
        const path = ring_mod.name(self.ring.allocator, snap_dir, entry.ns) catch return;
        defer self.ring.allocator.free(path);
        self.restore_id = link.send(proto.StatePath, .restore, .{ .path = path }) catch {
            self.step = .none;
            return;
        };
    }

    /// One frame with the rewind in flight: the advance goes out once the
    /// restore's answer has landed.
    pub fn rewind(self: *Snapshots, link: *Link) void {
        if (self.step != .advancing or self.advance_sent) return;
        const ns = self.going_ns - self.entry_ns;
        self.advance_id = link.send(proto.Advance, .advance, .{ .core = .cpu0, .ns = ns }) catch {
            self.step = .none;
            self.notice = "rewind refused";
            return;
        };
        self.advance_sent = true;
    }

    /// Ask for a session snapshot beside the link, this often, stamped
    /// with what the record shows.
    pub fn takeDue(self: *Snapshots, link: *Link, model: *const timeline_model.Model) void {
        if (self.snapshot_id != 0 or self.pending_path != null) return;
        const win = model.recorded() orelse return;
        if (win.to < self.stamped_ns + stamp_interval_ns) return;
        const path = ring_mod.name(self.ring.allocator, snap_dir, win.to) catch return;
        self.pending_path = self.ring.allocator.dupe(u8, path) catch return;
        self.pending_ns = win.to;
        self.snapshot_id = link.send(proto.StatePath, .snapshot, .{ .path = path }) catch return;
    }

    /// Take the rewind's and the snapshots' answers off the wire.
    pub fn observe(self: *Snapshots, arrival: session_link.Arrival) void {
        const response = switch (arrival) {
            .response => |one| one,
            .event => return,
        };
        if (self.step == .restoring and response.id == self.restore_id) {
            self.restore_id = 0;
            if (response.result != .ok) return self.fail();
            self.step = .advancing;
        }
        if (self.step == .advancing and response.id == self.advance_id) {
            self.advance_id = 0;
            self.advance_sent = false;
            self.step = .none;
        }
        if (self.snapshot_id != 0 and response.id == self.snapshot_id) {
            self.snapshot_id = 0;
            if (response.result != .ok) return self.dropPending();
            const path = self.pending_path orelse return;
            defer self.dropPending();
            if (self.ring.take(self.pending_ns, path)) {
                self.stamped_ns = self.pending_ns;
            } else |_| self.dropPending();
        }
    }

    fn dropPending(self: *Snapshots) void {
        if (self.pending_path) |path| self.ring.allocator.free(path);
        self.pending_path = null;
    }

    fn fail(self: *Snapshots) void {
        self.step = .none;
        self.notice = "rewind refused";
    }

    /// The record window as the record pane draws it.
    fn view(self: *const Snapshots, found: *const timeline_model.Model, area: draw_list.Rect) timeline_model.View {
        _ = self;
        const win = found.recorded() orelse return .{ .start_ns = 0, .span_ns = 1, .width_px = 1 };
        const rows = timeline_pane.rowsRect(area);
        return .{
            .start_ns = win.from,
            .span_ns = @max(win.to - win.from, 1),
            .width_px = @intCast(@max(rows.w, 1)),
        };
    }
};
