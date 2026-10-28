//! Temporary hot checkpoints for slow segment replay (Slice 22.3).
//! Segments longer than 250 ms virtual time lay temporary in-memory
//! checkpoints at 100 ms intervals during unpaced silent replay.
const std = @import("std");
const position_mod = @import("position.zig");

pub const Position = position_mod.Position;

/// Segments exceeding this virtual duration are split with temporary checkpoints.
pub const slow_threshold_ns: u64 = 250 * std.time.ns_per_ms;

/// The cadence at which temporary checkpoints are laid down within a slow segment.
pub const temp_interval_ns: u64 = 100 * std.time.ns_per_ms;

/// Whether a segment duration warrants temporary checkpoint splitting.
pub fn isSlow(duration_ns: u64) bool {
    return duration_ns > slow_threshold_ns;
}

/// One in-memory temporary checkpoint holding a saved machine snapshot.
pub const TempCheckpoint = struct {
    position: Position,
    virtual_ns: u64,
    bytes: []u8,

    pub fn deinit(self: *TempCheckpoint, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.bytes = &.{};
    }
};

/// In-memory store of temporary checkpoints laid down during segment replay.
pub const TempCheckpoints = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(TempCheckpoint) = .empty,

    pub fn init(allocator: std.mem.Allocator) TempCheckpoints {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TempCheckpoints) void {
        self.clear();
        self.items.deinit(self.allocator);
    }

    /// Drops all temporary checkpoints and frees their save bytes.
    pub fn clear(self: *TempCheckpoints) void {
        for (self.items.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.items.clearRetainingCapacity();
    }

    pub fn count(self: *const TempCheckpoints) usize {
        return self.items.items.len;
    }

    /// Stores a temporary hot checkpoint, copying the machine state bytes.
    pub fn add(self: *TempCheckpoints, position: Position, virtual_ns: u64, bytes: []const u8) !void {
        const copy = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(copy);
        try self.items.append(self.allocator, .{
            .position = position,
            .virtual_ns = virtual_ns,
            .bytes = copy,
        });
    }

    /// Finds the newest temporary checkpoint at or before `virtual_ns`.
    pub fn nearestAtOrBeforeNs(self: *const TempCheckpoints, virtual_ns: u64) ?TempCheckpoint {
        var best: ?TempCheckpoint = null;
        for (self.items.items) |entry| {
            if (entry.virtual_ns <= virtual_ns) {
                if (best == null or entry.virtual_ns > best.?.virtual_ns) {
                    best = entry;
                }
            }
        }
        return best;
    }

    /// Finds the newest temporary checkpoint at or before `pos`.
    pub fn nearestAtOrBefore(self: *const TempCheckpoints, pos: Position) ?TempCheckpoint {
        var best: ?TempCheckpoint = null;
        for (self.items.items) |entry| {
            if (entry.position.branch != pos.branch) continue;
            const ord = Position.order(entry.position, pos) orelse continue;
            if (ord != .gt) {
                if (best == null) {
                    best = entry;
                } else if (Position.order(entry.position, best.?.position)) |diff| {
                    if (diff == .gt) best = entry;
                }
            }
        }
        return best;
    }

    /// Calculates target timestamps for 100 ms split checkpoints if duration > 250 ms.
    pub fn planSplit(allocator: std.mem.Allocator, start_ns: u64, end_ns: u64) ![]u64 {
        if (end_ns <= start_ns) return allocator.alloc(u64, 0);
        const duration = end_ns - start_ns;
        if (!isSlow(duration)) return allocator.alloc(u64, 0);

        var list: std.ArrayList(u64) = .empty;
        errdefer list.deinit(allocator);

        var target = start_ns + temp_interval_ns;
        while (target < end_ns) : (target += temp_interval_ns) {
            try list.append(allocator, target);
        }
        return list.toOwnedSlice(allocator);
    }
};
