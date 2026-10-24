//! The served session's history bridge (RA8EMU-1196, slice 17): the
//! application half of the transport's bridge. A served session that
//! records history binds it, so a seek plans from the committed log and
//! puts the machine back through the checkpoint objects; a session with
//! no history binds nothing and its seeks stay refused.
const std = @import("std");
const ra8_session = @import("ra8_session");
const history = @import("ra8_host").history;
const history_bind = @import("history_bind.zig");
const history_ram = @import("history_ram.zig");

const seek_engine = ra8_session.history_seek_engine;
const seek_facts = ra8_session.history_seek_facts;

/// The bridge a served session binds: it reads the committed log for the
/// transport's planner and restores checkpoint objects into the session's
/// history. `disk` and `ram` are the two history kinds a served open
/// makes; exactly one is present.
pub const Bridge = struct {
    gpa: std.mem.Allocator,
    session: *ra8_session.api.Session,
    disk: ?*history_bind.Bind = null,
    ram: ?*history_ram.RamHistory = null,
    /// The facts the last gather returned; the bridge owns their memory
    /// until the next gather (the transport's bridge contract).
    facts_scratch: ?seek_facts.Facts = null,

    /// Drop the facts memory still owned at teardown.
    pub fn deinit(self: *Bridge) void {
        if (self.facts_scratch) |old| self.gpa.free(old.checkpoints);
        self.facts_scratch = null;
    }

    /// The committed log's facts for the transport's planner: the
    /// checkpoints the log names, with the live cursor from the session's
    /// grid (the log proves the rest; the cursor is the run's own).
    pub fn facts(context: *anyopaque) anyerror!seek_engine.Facts {
        const self: *Bridge = @ptrCast(@alignCast(context));
        if (self.facts_scratch) |old| self.gpa.free(old.checkpoints);
        self.facts_scratch = null;
        var disk_buf: ?[]u8 = null;
        defer if (disk_buf) |b| self.gpa.free(b);
        const bytes: []const u8 = blk: {
            if (self.ram) |r| break :blk r.log_bytes.items;
            if (self.disk) |d| {
                const len = try d.log.vtable.length(d.log.context);
                const buf = try self.gpa.alloc(u8, @intCast(len));
                disk_buf = buf;
                const total = try readAll(d.log, buf);
                break :blk buf[0..total];
            }
            return error.NoHistory;
        };
        const gathered = try seek_facts.gather(self.gpa, bytes);
        self.facts_scratch = gathered;
        // A never-run machine has no grid: its cursor sits at or before
        // every checkpoint, which a zeroed position says. A session with
        // no log still refuses above.
        if (self.session.grid) |grid| return .{ .current = grid.at, .checkpoints = gathered.checkpoints };
        return .{ .current = .{}, .checkpoints = gathered.checkpoints };
    }

    /// Put the machine back at a checkpoint's saved state; `object` is
    /// the checkpoint record's 128-bit digest as its 32-hex object name.
    pub fn restore(context: *anyopaque, object: []const u8) anyerror!void {
        const self: *Bridge = @ptrCast(@alignCast(context));
        const session_history = self.session.history orelse return error.NoHistory;
        if (self.ram) |r| {
            const bytes = r.get(object) orelse return error.ObjectMissing;
            return session_history.restoreBytes(bytes);
        }
        if (self.disk) |d| {
            const store = history.storage.Store.from(&d.session);
            var file = try store.vtable.open(store.context, .objects, object, .read);
            defer file.vtable.close(file.context);
            const len = try file.vtable.length(file.context);
            const buf = try self.gpa.alloc(u8, @intCast(len));
            defer self.gpa.free(buf);
            const total = try readAll(file, buf);
            return session_history.restoreBytes(buf[0..total]);
        }
        return error.NoHistory;
    }

    /// Returns the raw committed log bytes for in-RAM histories.
    pub fn logBytes(context: *anyopaque) anyerror![]const u8 {
        const self: *Bridge = @ptrCast(@alignCast(context));
        if (self.ram) |r| return r.log_bytes.items;
        return &[_]u8{};
    }
};

/// Read the file's bytes into `buf` from its start; a short file stops
/// at its end.
fn readAll(file: history.storage.ByteFile, buf: []u8) anyerror!usize {
    var total: usize = 0;
    while (total < buf.len) {
        const n = try file.vtable.read(file.context, @intCast(total), buf[total..]);
        if (n == 0) break;
        total += n;
    }
    return total;
}
