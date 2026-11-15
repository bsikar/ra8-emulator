//! Bounded whole-machine checkpoints for debugger edits, owned by History.
const std = @import("std");

const api = @import("api.zig");
const fork = @import("fork.zig");
const format = @import("history/format.zig");
const line = @import("line.zig");
const position_mod = @import("history/position.zig");
const record = @import("history/record.zig");
const state = @import("board/state.zig");

pub const max_snapshot_bytes = format.max_len - record.header_len - 6;
const Position = position_mod.Position;
const Entry = struct { bytes: []u8, position: Position };

pub const Journal = struct {
    pub const capacity = 16;
    allocator: std.mem.Allocator,
    files: *state.Files,
    clean: ?Entry = null,
    entries: std.ArrayList(Entry) = .empty,
    unavailable: ?anyerror = null,
    restoring: bool = false,

    pub fn init(allocator: std.mem.Allocator, files: *state.Files) Journal {
        return .{ .allocator = allocator, .files = files };
    }

    pub fn deinit(self: *Journal) void {
        self.clear();
        self.entries.deinit(self.allocator);
        if (self.clean) |entry| self.allocator.free(entry.bytes);
    }

    pub fn clear(self: *Journal) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.bytes);
        }
        self.entries.clearRetainingCapacity();
    }

    fn capture(self: *Journal) ![]u8 {
        var writer = std.Io.Writer.Allocating.init(self.allocator);
        defer writer.deinit();
        try self.files.writeTo(&writer.writer);
        if (writer.written().len > max_snapshot_bytes) return error.SnapshotTooLarge;
        return writer.toOwnedSlice();
    }

    /// A load replaces the reset point and all edits, even when its snapshot
    /// cannot be represented. Loading itself retains its existing semantics.
    pub fn loaded(self: *Journal) void {
        self.clear();
        if (self.clean) |entry| self.allocator.free(entry.bytes);
        self.clean = null;
        self.unavailable = null;
        const bytes = self.capture() catch |err| {
            self.unavailable = err;
            return;
        };
        self.clean = .{ .bytes = bytes, .position = self.position() };
    }

    fn position(self: *Journal) Position {
        return if (self.files.session) |session| session.currentPosition() else self.files.edge.saved.at;
    }

    /// Reserve before editing so an allocation failure cannot lose an undo.
    pub fn prepare(self: *Journal) !?[]u8 {
        try self.entries.ensureTotalCapacity(self.allocator, capacity);
        const bytes = self.capture() catch |err| switch (err) {
            error.SecondCoreNotSaved, error.UnsupportedAttachments, error.SnapshotTooLarge => {
                self.clear();
                self.unavailable = err;
                return null;
            },
            else => return err,
        };
        self.unavailable = null;
        return bytes;
    }

    pub fn committed(self: *Journal, bytes: []u8) void {
        if (self.entries.items.len == capacity) {
            self.allocator.free(self.entries.orderedRemove(0).bytes);
        }
        self.entries.appendAssumeCapacity(.{ .bytes = bytes, .position = self.position() });
    }

    fn restore(self: *Journal, entry: Entry) !void {
        self.restoring = true;
        defer self.restoring = false;
        if (self.files.session) |session| {
            if (session.fork_router) |router| {
                if (router.graph == null) return error.RecordedHistoryActive;
                try preflightRestore(session, entry.bytes);
                // The child owns its fork point, even when several edits share
                // one scheduler position. The restore record carries them all.
                var target = entry.position;
                target.branch = router.active_line;
                try fork.executeFork(session, .writes, target, .{ .restore = entry.bytes });
                router.cancel();
                return;
            }
            if (session.persistent_recorder != null) return error.RecordedHistoryActive;
        }
        try self.files.readFrom(entry.bytes);
    }

    pub fn undo(self: *Journal) !void {
        if (self.unavailable) |err| return err;
        if (self.entries.items.len == 0) return error.NoUndo;
        const entry = self.entries.items[self.entries.items.len - 1];
        try self.restore(entry);
        _ = self.entries.pop();
        self.allocator.free(entry.bytes);
    }

    pub fn reset(self: *Journal) !void {
        if (self.unavailable) |err| return err;
        try self.restore(self.clean orelse return error.NoCleanImage);
        self.clear();
    }
};

/// Recovery is whole-machine and only begins while every core is halted.
fn journal(self: *api.Session) !*Journal {
    if (self.replaying) return error.ReplayActive;
    if (self.advancing or self.live.machine.mode != .halted) return error.Running;
    if (self.live.other) |other| if (other.machine.mode != .halted) return error.Running;
    const history = self.history orelse return error.NoHistory;
    return &history.edits;
}

pub fn undoWrite(self: *api.Session) anyerror!void {
    try (try journal(self)).undo();
    recovered(self);
}

pub fn resetImage(self: *api.Session) anyerror!void {
    try (try journal(self)).reset();
    recovered(self);
}

/// Replayed writes do not become new user edits. Forked live edits do.
pub fn prepare(self: *api.Session) !?[]u8 {
    if (self.replaying) return null;
    const history = self.history orelse return null;
    return history.edits.prepare();
}

pub fn finish(self: *api.Session, bytes: ?[]u8, succeeded: bool) void {
    const owned = bytes orelse return;
    const edits = &self.history.?.edits;
    if (succeeded) edits.committed(owned) else edits.allocator.free(owned);
}

pub fn loaded(self: *api.Session) void {
    if (self.replaying) return;
    if (self.history) |history| history.edits.loaded();
}

/// Reject a payload beyond the existing log frame cap before making a branch.
pub fn preflightRestore(self: *api.Session, bytes: []const u8) !void {
    if (bytes.len > max_snapshot_bytes) return error.SnapshotTooLarge;
    const history = self.history orelse return error.NoHistory;
    try history.files.single();
}

/// A restore intervention is replayable guest state, with its grid stamped
/// onto the line replay is following rather than the snapshot's source line.
pub fn applyRestore(self: *api.Session, bytes: []const u8) !void {
    try preflightRestore(self, bytes);
    const history = self.history.?;
    try history.files.readFrom(bytes);
    line.stampLine(self);
}

fn recovered(self: *api.Session) void {
    for ([_]api.Core{ .cpu0, .cpu1 }) |core| {
        if (self.hasCore(core)) self.publish(.{ .core = core, .kind = .rewound });
    }
    const board = self.history.?.files.board;
    for (&self.event_sources.led_on, 0..) |*on, index| {
        on.* = board.pins.ledLevel(index) == 1;
        self.publish(.{
            .core = .cpu0,
            .kind = .led_changed,
            .payload = .{ .led = .{ .index = @intCast(index), .level = on.* } },
        });
    }
}
