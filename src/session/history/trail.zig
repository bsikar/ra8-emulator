//! The recording run's joined trail (unit 09): one observer per space, one
//! ordered list, one restore.
//!
//! A recording machine owns exactly one trail. The machine store's single
//! observer slot carries it, and a borrower store chases the lender's, so
//! the first core's write hook (H1), the second core's fast path (H2) and
//! every structural barrier (H5) land in one ordered list however many
//! stores write. A component's own hooks (H3/H6) record in the component's
//! own address space, so the machine hands each component an observer of
//! its own that tags its records with the part index, and the trail holds
//! that part's restore: this is how the join attributes the access path.
//!
//! Every byte record holds the pre-image, who wrote, and the writing
//! core's live slot count, so the undo replays the list backwards through
//! the raw restore paths, and each stamped barrier marks where the bytes
//! before it no longer describe the storage: the replay stops above it,
//! and the barrier's own structural restore goes through the part's
//! snapshot, not the byte list.
//!
//! The pre-image is copied at the hook, because the observer contract
//! hands it over only for the call. An allocation that fails poisons the
//! recording instead of dropping the record silently: the trail would
//! otherwise restore bytes it never held, so `healthy` reports the poison
//! and no undo past it is trustworthy.

const std = @import("std");
const memory = @import("ra8_chip").core.cpu.memory;
const observer = memory.observer;
const store_mod = memory.store;
const initiator_mod = memory.initiator;
const types = @import("trail_types.zig");

const Allocator = std.mem.Allocator;
const Initiator = initiator_mod.Initiator;

pub const Source = types.Source;
pub const Core = types.Core;
pub const Bytes = types.Bytes;
pub const Record = types.Record;
pub const Watch = types.Watch;
pub const Hit = types.Hit;
pub const PartRestore = types.PartRestore;

const machine_hooks = observer.Observer.VTable{ .bytes = machineBytes, .barrier = machineBarrier };
const part_hooks = observer.Observer.VTable{ .bytes = partBytes, .barrier = partBarrier };

/// The per-part observer's context. One exists per wired part and is kept
/// for the recording's lifetime, because an attached observer holds it.
const Node = struct {
    owner: *Recording,
    part: u16,
};

fn machineBytes(ctx: *anyopaque, write: observer.Write) void {
    const self: *Recording = @ptrCast(@alignCast(ctx));
    if (self.attached) self.takeBytes(write, null);
    if (self.prev) |prev| prev.bytes(write);
}

fn machineBarrier(ctx: *anyopaque, event: observer.Barrier) void {
    const self: *Recording = @ptrCast(@alignCast(ctx));
    if (self.attached) self.takeBarrier(event);
    if (self.prev) |prev| prev.barrier(event);
}

fn partBytes(ctx: *anyopaque, write: observer.Write) void {
    const node: *Node = @ptrCast(@alignCast(ctx));
    node.owner.takeBytes(write, node.part);
}

fn partBarrier(ctx: *anyopaque, event: observer.Barrier) void {
    const node: *Node = @ptrCast(@alignCast(ctx));
    node.owner.takeBarrier(event);
}

/// The recording run's joined trail.
pub const Recording = struct {
    allocator: Allocator,
    store: *store_mod.Store,
    /// The two cores' cumulative slot counters, cpu0 first.
    slots: [2]*const u64,
    records: []Record = &.{},
    record_count: usize = 0,
    record_capacity: usize = 0,
    parts: []PartRestore = &.{},
    part_count: usize = 0,
    part_capacity: usize = 0,
    nodes: []*Node = &.{},
    node_count: usize = 0,
    watches: []Watch = &.{},
    watch_count: usize = 0,
    hits: []Hit = &.{},
    hit_count: usize = 0,
    attached: bool = false,
    /// An allocation failed mid-hook and a record was lost; the undo past
    /// this point is untrustworthy and must not be trusted.
    poisoned: bool = false,
    observer: observer.Observer = .{ .ctx = undefined, .vtable = &machine_hooks },
    /// The observer the store held before the trail joined it: every
    /// write still reaches it, recorded or not.
    prev: ?*const observer.Observer = null,
    /// Whether the trail sits in the store's observer chain.
    linked: bool = false,

    /// The trail starts unarmed: the machine arms it when its run records.
    pub fn init(allocator: Allocator, slots: [2]*const u64, store: *store_mod.Store) Recording {
        return .{ .allocator = allocator, .store = store, .slots = slots };
    }

    /// Start recording. The first arm joins the store's observer slot in
    /// front of whatever held it, which keeps seeing every write; a
    /// borrower store chases the lender's, so one machine records one
    /// trail however many stores write. Observers join and leave the
    /// store's chain last in, first out (checkpoints' dirty pages, then
    /// the trail, then the frame tap), so each one leaves as the head.
    pub fn arm(self: *Recording) void {
        if (!self.linked) {
            self.observer = .{ .ctx = self, .vtable = &machine_hooks };
            self.prev = self.store.observer;
            self.store.observer = &self.observer;
            self.linked = true;
        }
        self.attached = true;
    }

    /// Stop recording. The trail stays in the chain, passing writes on.
    pub fn disarm(self: *Recording) void {
        self.attached = false;
    }

    /// Leave the store's chain, giving the slot back to the observer the
    /// trail joined in front of. One that joined since holds the trail's
    /// observer and is not this call's to take.
    fn unlink(self: *Recording) void {
        if (self.linked and self.store.observer == &self.observer) self.store.observer = self.prev;
        self.linked = false;
        self.attached = false;
    }

    pub fn deinit(self: *Recording) void {
        self.unlink();
        for (self.records[0..self.record_count]) |*record| switch (record.*) {
            .bytes => |*bytes| bytes.deinit(self.allocator),
            .barrier => {},
        };
        if (self.record_capacity != 0) self.allocator.free(self.records);
        if (self.part_capacity != 0) self.allocator.free(self.parts);
        for (self.nodes[0..self.node_count]) |node| self.allocator.destroy(node);
        if (self.node_count != 0) self.allocator.free(self.nodes);
        for (self.watches[0..self.watch_count]) |one| self.allocator.free(one.label);
        if (self.watch_count != 0) self.allocator.free(self.watches);
        if (self.hit_count != 0) self.allocator.free(self.hits);
        self.* = undefined;
    }

    /// A record was lost to a failed allocation; no undo past it can be
    /// trusted, because the trail would restore bytes it never held.
    pub fn healthy(self: *const Recording) bool {
        return !self.poisoned;
    }

    /// The records so far, oldest first.
    pub fn slice(self: *const Recording) []Record {
        return self.records[0..self.record_count];
    }

    /// Register a component's own restore and get back the index its
    /// observer tags records with.
    pub fn addPart(self: *Recording, restore: PartRestore) !u16 {
        try self.growParts();
        self.parts[self.part_count] = restore;
        const index: u16 = @intCast(self.part_count);
        self.part_count += 1;
        return index;
    }

    /// The observer a component's hooks record through: it tags every
    /// record with the part index, so the undo routes the part's records
    /// through the part's own raw restore.
    pub fn partObserver(self: *Recording, index: u16) !observer.Observer {
        const node = try self.allocator.create(Node);
        errdefer self.allocator.destroy(node);
        node.* = .{ .owner = self, .part = index };
        try self.growNodes();
        self.nodes[self.node_count] = node;
        self.node_count += 1;
        return .{ .ctx = node, .vtable = &part_hooks };
    }

    /// Watch a range for writes outside the two cores, under a label the
    /// trail keeps its own copy of.
    pub fn watch(self: *Recording, base: u32, size: u32, label: []const u8) !void {
        const owned = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(owned);
        try self.growWatches();
        self.watches[self.watch_count] = .{ .base = base, .size = size, .label = owned };
        self.watch_count += 1;
    }

    pub fn watchSlice(self: *const Recording) []Watch {
        return self.watches[0..self.watch_count];
    }

    pub fn hitSlice(self: *const Recording) []Hit {
        return self.hits[0..self.hit_count];
    }

    /// Replay the recorded writes backwards through the raw restore paths,
    /// down to the nearest stamped barrier, and drop the records it
    /// replayed: the classic undo log. The bytes land exactly as they were
    /// recorded, past the write gates, the MPU and NOR program semantics,
    /// which is what the pre-image was taken from. Returns how many byte
    /// records it replayed. The barrier stays as the boundary, because its
    /// own structural restore goes through the part's snapshot.
    pub fn undo(self: *Recording) !usize {
        var replayed: usize = 0;
        while (self.record_count > 0) {
            switch (self.records[self.record_count - 1]) {
                .bytes => |*bytes| {
                    if (bytes.part) |index| {
                        const restore = self.parts[index];
                        restore.raw(restore.ctx, @intCast(bytes.offset), bytes.pre);
                    } else {
                        try self.store.rawWrite(@intCast(bytes.base + bytes.offset), bytes.pre);
                    }
                    bytes.deinit(self.allocator);
                    self.record_count -= 1;
                    replayed += 1;
                },
                .barrier => return replayed,
            }
        }
        return replayed;
    }

    fn takeBytes(self: *Recording, write: observer.Write, part: ?u16) void {
        const pre = self.allocator.dupe(u8, write.pre) catch {
            self.poisoned = true;
            return;
        };
        self.growRecords() catch {
            self.allocator.free(pre);
            self.poisoned = true;
            return;
        };
        const source: Source = switch (write.initiator) {
            .cpu0 => .{ .core = .{ .core = .cpu0, .slots = self.slots[0].* } },
            .cpu1 => .{ .core = .{ .core = .cpu1, .slots = self.slots[1].* } },
            .none => .untimed,
            else => .{ .board = write.initiator },
        };
        self.records[self.record_count] = .{ .bytes = .{
            .base = write.base,
            .offset = write.offset,
            .initiator = write.initiator,
            .source = source,
            .part = part,
            .pre = pre,
        } };
        self.record_count += 1;
        self.noteHits(write, part != null);
    }

    fn takeBarrier(self: *Recording, event: observer.Barrier) void {
        self.growRecords() catch {
            self.poisoned = true;
            return;
        };
        self.records[self.record_count] = .{ .barrier = event };
        self.record_count += 1;
    }

    /// Board-phase writes raise labelled hits where they overlap a watch.
    /// A part-space write raises one too when the trail cannot name the
    /// driver: the hit is honest about that instead of silent.
    fn noteHits(self: *Recording, write: observer.Write, from_part: bool) void {
        if (self.watch_count == 0) return;
        switch (write.initiator) {
            .cpu0, .cpu1 => return,
            else => {},
        }
        const start: u64 = @as(u64, write.base) + write.offset;
        const end: u64 = start + write.pre.len;
        for (self.watches[0..self.watch_count], 0..) |entry, index| {
            const from: u64 = entry.base;
            const to: u64 = from + entry.size;
            if (start >= to or end <= from) continue;
            self.growHits() catch {
                self.poisoned = true;
                return;
            };
            const source: Source = if (from_part) .untimed else switch (write.initiator) {
                .none => .untimed,
                else => .{ .board = write.initiator },
            };
            self.hits[self.hit_count] = .{
                .watch = index,
                .start = start,
                .len = write.pre.len,
                .initiator = write.initiator,
                .source = source,
            };
            self.hit_count += 1;
        }
    }

    fn growRecords(self: *Recording) !void {
        if (self.record_count < self.record_capacity) return;
        const next = if (self.record_capacity == 0) 16 else self.record_capacity * 2;
        const grown = try self.allocator.alloc(Record, next);
        @memcpy(grown[0..self.record_count], self.records[0..self.record_count]);
        if (self.record_capacity != 0) self.allocator.free(self.records);
        self.records = grown;
        self.record_capacity = next;
    }

    fn growParts(self: *Recording) !void {
        if (self.part_count < self.part_capacity) return;
        const next = if (self.part_capacity == 0) 4 else self.part_capacity * 2;
        const grown = try self.allocator.alloc(PartRestore, next);
        @memcpy(grown[0..self.part_count], self.parts[0..self.part_count]);
        if (self.part_capacity != 0) self.allocator.free(self.parts);
        self.parts = grown;
        self.part_capacity = next;
    }

    fn growNodes(self: *Recording) !void {
        if (self.node_count < self.nodes.len) return;
        const next = if (self.nodes.len == 0) 4 else self.nodes.len * 2;
        const grown = try self.allocator.alloc(*Node, next);
        @memcpy(grown[0..self.node_count], self.nodes[0..self.node_count]);
        if (self.nodes.len != 0) self.allocator.free(self.nodes);
        self.nodes = grown;
    }

    fn growWatches(self: *Recording) !void {
        if (self.watch_count < self.watches.len) return;
        const next = if (self.watches.len == 0) 4 else self.watches.len * 2;
        const grown = try self.allocator.alloc(Watch, next);
        @memcpy(grown[0..self.watch_count], self.watches[0..self.watch_count]);
        if (self.watches.len != 0) self.allocator.free(self.watches);
        self.watches = grown;
    }

    fn growHits(self: *Recording) !void {
        if (self.hit_count < self.hits.len) return;
        const next = if (self.hits.len == 0) 8 else self.hits.len * 2;
        const grown = try self.allocator.alloc(Hit, next);
        @memcpy(grown[0..self.hit_count], self.hits[0..self.hit_count]);
        if (self.hits.len != 0) self.allocator.free(self.hits);
        self.hits = grown;
    }
};
