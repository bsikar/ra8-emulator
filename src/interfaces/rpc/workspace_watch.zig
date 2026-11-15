//! Per-connection metadata watches: bounded paths, no worker or handle per watch.
const std = @import("std");
const host = @import("ra8_host").workspace;
const wire = @import("workspace_wire.zig");
const Context = @import("session/handlers.zig").Context;
pub const capacity = 8;
const Slot = struct { id: u32 = 0, path: [host.path.capacity]u8 = undefined, len: usize = 0, version: host.observation.Snapshot = .{} };
pub const Table = struct {
    slots: [capacity]Slot = @splat(.{}),
    next_id: u32 = 1,
    next_poll_ns: i96 = 0,
    cursor: usize = 0,

    pub fn clear(self: *Table) void {
        for (&self.slots) |*slot| slot.id = 0;
    }

    pub fn add(self: *Table, path: []const u8, version: host.observation.Snapshot) !u32 {
        if (path.len > host.path.capacity) return error.NameTooLong;
        if (self.next_id == std.math.maxInt(u32)) return error.TooManyWatches;
        for (&self.slots) |*slot| {
            if (slot.id != 0) continue;
            @memcpy(slot.path[0..path.len], path);
            slot.len = path.len;
            slot.version = version;
            slot.id = self.next_id;
            self.next_id += 1;
            return slot.id;
        }
        return error.TooManyWatches;
    }

    pub fn remove(self: *Table, id: u32) !void {
        if (id != 0) for (&self.slots) |*slot| {
            if (slot.id == id) {
                slot.id = 0;
                return;
            }
        };
        return error.InvalidWatch;
    }
};

/// Reconcile at most eight paths between frames; intermediate changes can coalesce.
pub fn pump(context: *Context, server: anytype, tx: []u8) !void {
    const root = context.workspace orelse return;
    const table = &context.workspace_watches;
    const now = std.Io.Clock.awake.now(root.io).nanoseconds;
    if (now < table.next_poll_ns) return;
    table.next_poll_ns = now + 100_000_000;
    for (0..capacity) |_| {
        const slot = &table.slots[table.cursor];
        table.cursor = (table.cursor + 1) % capacity;
        if (slot.id == 0) continue;
        const path = slot.path[0..slot.len];
        var encoded: [wire.version_bytes]u8 = undefined;
        const version = root.observe(path) catch {
            try server.emit(wire.Change, wire.changed_topic, .{ .id = slot.id, .state = .unavailable, .path = path, .version = try wire.encodeVersion(.{}, &encoded) }, tx);
            slot.id = 0;
            return;
        };
        if (version.same(slot.version)) return;
        try server.emit(wire.Change, wire.changed_topic, .{ .id = slot.id, .state = if (version.version.kind == .missing) .removed else .changed, .path = path, .version = try wire.encodeVersion(version.version, &encoded) }, tx);
        slot.version = version;
        return;
    }
}
