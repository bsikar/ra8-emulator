//! Position-stamped navigation indexes (Slice 22.4).
//! Indexes frames, loop iterations (with k*n architectural slot counting),
//! markers/bookmarks, and RTOS thread switches / ISR transitions.
//! All position comparisons are line-aware.
const std = @import("std");
const position_mod = @import("position.zig");
const branch_mod = @import("branch.zig");
const seek_target = @import("seek_target.zig");

pub const Position = position_mod.Position;
pub const BranchGraph = branch_mod.BranchGraph;
pub const BranchId = branch_mod.BranchId;

pub const FrameEntry = struct {
    index: u64,
    position: Position,
    virtual_ns: u64 = 0,
};

pub const IterationEntry = struct {
    n: u64,
    position: Position,
    slots: u64,
};

pub const MarkerArrival = struct {
    name: []const u8,
    address: ?u32 = null,
    position: Position,
    nth: u64,
    /// The length of the log the arrival was indexed over; null for an
    /// arrival the history's start fixes for good.
    end: ?u64 = null,
};

pub const RtosSwitch = struct {
    from_thread: u32,
    to_thread: u32,
    position: Position,
    core: u1 = 0,
};

pub const IsrTransition = struct {
    exception: u16,
    is_entry: bool,
    position: Position,
    core: u1 = 0,
};

pub const CompareFn = *const fn (ctx: ?*const anyopaque, a: Position, b: Position) std.math.Order;

pub const NavIndex = struct {
    allocator: std.mem.Allocator,
    frames: std.ArrayListUnmanaged(FrameEntry) = .empty,
    iterations: std.ArrayListUnmanaged(IterationEntry) = .empty,
    marker_arrivals: std.ArrayListUnmanaged(MarkerArrival) = .empty,
    bookmarks: std.StringHashMapUnmanaged(Position) = .empty,
    rtos_switches: std.ArrayListUnmanaged(RtosSwitch) = .empty,
    isr_transitions: std.ArrayListUnmanaged(IsrTransition) = .empty,
    accumulated_slots: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) NavIndex {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *NavIndex) void {
        self.frames.deinit(self.allocator);
        self.iterations.deinit(self.allocator);
        for (self.marker_arrivals.items) |m| {
            self.allocator.free(m.name);
        }
        self.marker_arrivals.deinit(self.allocator);
        var it = self.bookmarks.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.bookmarks.deinit(self.allocator);
        self.rtos_switches.deinit(self.allocator);
        self.isr_transitions.deinit(self.allocator);
    }

    pub fn addFrame(self: *NavIndex, pos: Position, virtual_ns: u64) !u64 {
        const idx = self.frames.items.len;
        try self.frames.append(self.allocator, .{
            .index = idx,
            .position = pos,
            .virtual_ns = virtual_ns,
        });
        return idx;
    }

    /// Indexes a frame unless a replay passed back over one already indexed
    /// further on, so a seek's replay never lists the same frame twice.
    pub fn addFrameIfNotBehind(self: *NavIndex, pos: Position, virtual_ns: u64) !?u64 {
        if (self.frames.items.len > 0) {
            const last = self.frames.items[self.frames.items.len - 1].position;
            const order = position_mod.compare(pos, last) catch .gt;
            if (order == .lt) return null;
        }
        return try self.addFrame(pos, virtual_ns);
    }

    pub fn getFrame(self: *const NavIndex, index: u64) ?Position {
        if (index < self.frames.items.len) {
            return self.frames.items[@intCast(index)].position;
        }
        return null;
    }

    pub fn frameCount(self: *const NavIndex) usize {
        return self.frames.items.len;
    }

    pub fn prevFrame(
        self: *const NavIndex,
        cursor: Position,
        cmp_ctx: ?*const anyopaque,
        cmp_fn: ?CompareFn,
    ) ?Position {
        return findAdjacent(self.frames.items, cursor, cmp_ctx, cmp_fn, .prev);
    }

    pub fn nextFrame(
        self: *const NavIndex,
        cursor: Position,
        cmp_ctx: ?*const anyopaque,
        cmp_fn: ?CompareFn,
    ) ?Position {
        return findAdjacent(self.frames.items, cursor, cmp_ctx, cmp_fn, .next);
    }

    pub fn addIteration(self: *NavIndex, pos: Position) !u64 {
        const n = self.iterations.items.len + 1;
        try self.iterations.append(self.allocator, .{
            .n = n,
            .position = pos,
            .slots = self.accumulated_slots,
        });
        return n;
    }

    pub fn advanceSlots(self: *NavIndex, count: u64) void {
        self.accumulated_slots += count;
    }

    pub fn getIteration(self: *const NavIndex, n: u64) ?Position {
        if (n >= 1 and n <= self.iterations.items.len) {
            return self.iterations.items[@intCast(n - 1)].position;
        }
        return null;
    }

    pub fn getIterationSlots(self: *const NavIndex, n: u64) ?u64 {
        if (n >= 1 and n <= self.iterations.items.len) {
            return self.iterations.items[@intCast(n - 1)].slots;
        }
        return null;
    }

    pub fn iterationCount(self: *const NavIndex) usize {
        return self.iterations.items.len;
    }

    pub fn prevIteration(
        self: *const NavIndex,
        cursor: Position,
        cmp_ctx: ?*const anyopaque,
        cmp_fn: ?CompareFn,
    ) ?Position {
        return findAdjacent(self.iterations.items, cursor, cmp_ctx, cmp_fn, .prev);
    }

    pub fn nextIteration(
        self: *const NavIndex,
        cursor: Position,
        cmp_ctx: ?*const anyopaque,
        cmp_fn: ?CompareFn,
    ) ?Position {
        return findAdjacent(self.iterations.items, cursor, cmp_ctx, cmp_fn, .next);
    }

    pub fn addMarkerArrival(
        self: *NavIndex,
        name: []const u8,
        address: ?u32,
        pos: Position,
    ) !u64 {
        return self.addMarkerArrivalAt(name, address, pos, null);
    }

    /// An arrival indexed over a log of `end` bytes.
    pub fn addMarkerArrivalAt(
        self: *NavIndex,
        name: []const u8,
        address: ?u32,
        pos: Position,
        end: ?u64,
    ) !u64 {
        var nth: u64 = 1;
        for (self.marker_arrivals.items) |m| {
            if (std.mem.eql(u8, m.name, name)) {
                nth += 1;
            }
        }
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.marker_arrivals.append(self.allocator, .{
            .name = owned_name,
            .address = address,
            .position = pos,
            .nth = nth,
            .end = end,
        });
        return nth;
    }

    /// Drops every marker indexed over a log other than `end` bytes long: a
    /// history that grew past it has arrivals those markers do not hold,
    /// so they are armed again by the next request.
    pub fn dropStaleMarkers(self: *NavIndex, end: u64) void {
        var kept: usize = 0;
        for (self.marker_arrivals.items) |m| {
            if (m.end) |at| if (at != end) {
                self.allocator.free(m.name);
                continue;
            };
            self.marker_arrivals.items[kept] = m;
            kept += 1;
        }
        self.marker_arrivals.shrinkRetainingCapacity(kept);
    }

    pub fn getMarkerArrival(self: *const NavIndex, name: []const u8, nth: u64) ?Position {
        for (self.marker_arrivals.items) |m| {
            if (m.nth == nth and std.mem.eql(u8, m.name, name)) {
                return m.position;
            }
        }
        return null;
    }

    /// The nearest entry of one index before or after `cursor`.
    pub fn stepFrom(
        self: *const NavIndex,
        kind: @FieldType(seek_target.Step, "kind"),
        dir: @FieldType(seek_target.Step, "dir"),
        cursor: Position,
        cmp_ctx: ?*const anyopaque,
        cmp_fn: ?CompareFn,
    ) ?Position {
        const back = dir == .prev;
        return switch (kind) {
            .iteration => if (back) self.prevIteration(cursor, cmp_ctx, cmp_fn) else self.nextIteration(cursor, cmp_ctx, cmp_fn),
            .rtos => if (back) self.prevRtosSwitch(cursor, cmp_ctx, cmp_fn) else self.nextRtosSwitch(cursor, cmp_ctx, cmp_fn),
            .isr => if (back) self.prevIsr(cursor, cmp_ctx, cmp_fn) else self.nextIsr(cursor, cmp_ctx, cmp_fn),
        };
    }

    /// How many arrivals the marker `name` has indexed so far.
    pub fn markerArrivalCount(self: *const NavIndex, name: []const u8) usize {
        var count: usize = 0;
        for (self.marker_arrivals.items) |m| {
            if (std.mem.eql(u8, m.name, name)) count += 1;
        }
        return count;
    }

    pub fn getPointArrival(self: *const NavIndex, address: u32, nth: u64) ?Position {
        var seen: u64 = 0;
        for (self.marker_arrivals.items) |m| {
            if (m.address != null and m.address.? == address) {
                seen += 1;
                if (seen == nth) return m.position;
            }
        }
        return null;
    }

    pub fn setBookmark(self: *NavIndex, name: []const u8, pos: Position) !void {
        if (self.bookmarks.getEntry(name)) |entry| {
            entry.value_ptr.* = pos;
            return;
        }
        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);
        try self.bookmarks.put(self.allocator, owned, pos);
    }

    pub fn getBookmark(self: *const NavIndex, name: []const u8) ?Position {
        return self.bookmarks.get(name);
    }

    pub fn addRtosSwitch(
        self: *NavIndex,
        from_thread: u32,
        to_thread: u32,
        pos: Position,
        core: u1,
    ) !void {
        try self.rtos_switches.append(self.allocator, .{
            .from_thread = from_thread,
            .to_thread = to_thread,
            .position = pos,
            .core = core,
        });
    }

    pub fn rtosSwitchCount(self: *const NavIndex) usize {
        return self.rtos_switches.items.len;
    }

    pub fn prevRtosSwitch(
        self: *const NavIndex,
        cursor: Position,
        cmp_ctx: ?*const anyopaque,
        cmp_fn: ?CompareFn,
    ) ?Position {
        return findAdjacent(self.rtos_switches.items, cursor, cmp_ctx, cmp_fn, .prev);
    }

    pub fn nextRtosSwitch(
        self: *const NavIndex,
        cursor: Position,
        cmp_ctx: ?*const anyopaque,
        cmp_fn: ?CompareFn,
    ) ?Position {
        return findAdjacent(self.rtos_switches.items, cursor, cmp_ctx, cmp_fn, .next);
    }

    pub fn addIsr(
        self: *NavIndex,
        exception: u16,
        is_entry: bool,
        pos: Position,
        core: u1,
    ) !void {
        try self.isr_transitions.append(self.allocator, .{
            .exception = exception,
            .is_entry = is_entry,
            .position = pos,
            .core = core,
        });
    }

    pub fn isrTransitionCount(self: *const NavIndex) usize {
        return self.isr_transitions.items.len;
    }

    pub fn prevIsr(
        self: *const NavIndex,
        cursor: Position,
        cmp_ctx: ?*const anyopaque,
        cmp_fn: ?CompareFn,
    ) ?Position {
        return findAdjacent(self.isr_transitions.items, cursor, cmp_ctx, cmp_fn, .prev);
    }

    pub fn nextIsr(
        self: *const NavIndex,
        cursor: Position,
        cmp_ctx: ?*const anyopaque,
        cmp_fn: ?CompareFn,
    ) ?Position {
        return findAdjacent(self.isr_transitions.items, cursor, cmp_ctx, cmp_fn, .next);
    }
};

fn findAdjacent(
    items: anytype,
    cursor: Position,
    cmp_ctx: ?*const anyopaque,
    cmp_fn: ?CompareFn,
    dir: enum { prev, next },
) ?Position {
    var best: ?Position = null;
    const target_ord: std.math.Order = if (dir == .prev) .lt else .gt;
    const better_ord: std.math.Order = if (dir == .prev) .gt else .lt;
    for (items) |item| {
        const ord = comparePos(cmp_ctx, cmp_fn, item.position, cursor);
        if (ord == target_ord) {
            if (best == null or comparePos(cmp_ctx, cmp_fn, item.position, best.?) == better_ord) {
                best = item.position;
            }
        }
    }
    return best;
}

fn comparePos(
    ctx: ?*const anyopaque,
    cmp_fn: ?CompareFn,
    a: Position,
    b: Position,
) std.math.Order {
    if (cmp_fn) |f| return f(ctx, a, b);
    return position_mod.compare(a, b) catch .eq;
}
