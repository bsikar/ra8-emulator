//! The slice-click's snapshot ring (RA8EMU-838): the client keeps the path
//! of every session snapshot it asked for, stamped with the board time it
//! holds, so a click over a slice can restore the newest at or before the
//! slice's start. Paths live on the serving host; eviction is oldest-first.

const std = @import("std");

/// How many snapshots the client keeps beside the link.
pub const capacity = 12;

pub const Entry = struct {
    /// The board time the snapshot holds.
    ns: u64,
    /// Where the file sits on the serving host. Owned by the ring.
    path: []const u8,
};

pub const Ring = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry),

    pub fn init(allocator: std.mem.Allocator) Ring {
        return .{ .allocator = allocator, .entries = .empty };
    }

    pub fn deinit(self: *Ring) void {
        for (self.entries.items) |one| self.allocator.free(one.path);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    /// Stamp a snapshot the server just wrote. `path` is copied. A full ring
    /// evicts its oldest whole entry first.
    pub fn take(self: *Ring, ns: u64, path: []const u8) !void {
        if (self.entries.items.len >= capacity) self.dropOldest();
        const owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned);
        try self.entries.append(self.allocator, .{ .ns = ns, .path = owned });
    }

    /// The newest snapshot at or before `ns`, or null when the run has no
    /// snapshot kept this far back.
    pub fn atOrBefore(self: *const Ring, ns: u64) ?Entry {
        var newest: ?Entry = null;
        for (self.entries.items) |one| {
            if (one.ns > ns) continue;
            if (newest == null or one.ns > newest.?.ns) newest = one;
        }
        return newest;
    }

    fn dropOldest(self: *Ring) void {
        if (self.entries.items.len == 0) return;
        const oldest = self.entries.items[0];
        self.allocator.free(oldest.path);
        _ = self.entries.orderedRemove(0);
    }
};

/// The path a snapshot of `ns` is written to: `<dir>/snap-<ns>.ra8run`.
pub fn name(allocator: std.mem.Allocator, dir: []const u8, ns: u64) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/snap-{d}.ra8run", .{ dir, ns });
}

/// The board time a snapshot path was stamped with, or null for a path the
/// ring did not write.
pub fn stampOf(path: []const u8) ?u64 {
    const base = "snap-";
    const ext = ".ra8run";
    const start = if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| slash + 1 else 0;
    const stem = path[start..];
    if (stem.len <= base.len + ext.len or !std.mem.startsWith(u8, stem, base) or !std.mem.endsWith(u8, stem, ext)) return null;
    return std.fmt.parseInt(u64, stem[base.len .. stem.len - ext.len], 10) catch null;
}
