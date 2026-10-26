//! The reverse window (section 2.5): a byte-bounded run of slots on one
//! line, [start, end], with a cursor inside it, built once by replay and
//! then walked slot by slot in either direction.
//!
//! Each slot keeps the joined trail's byte records and register deltas
//! (window_trail.zig) for guest memory and the core, and an XOR delta of
//! the state beside guest memory (window_delta.zig). A slot whose delta
//! stays inside the core and clock sections is a RAM/CPU slot: undo and
//! redo swap its bytes and put the core sections back. Any other slot
//! touched the board: undo restores its pre-state sections, and redo
//! re-executes it from that pre-state and checks the stored post digest,
//! refusing visibly with the slot's position on a mismatch.
//!
//! A hot checkpoint, the whole save stream, sits at or before the window
//! start, so a window that evicted its oldest slots can still be rebuilt.
//! The window belongs to the line it was built on: switching lines or a
//! fork drops it. Building lives in window_rebuild.zig, the per-slot
//! recording in window_record.zig.
const std = @import("std");
const trail_mod = @import("trail.zig");
const wtrail_mod = @import("window_trail.zig");
const delta_mod = @import("window_delta.zig");
const digest_mod = @import("window_digest.zig");
const port_mod = @import("window_port.zig");
const record = @import("window_record.zig");
const rebuild_mod = @import("window_rebuild.zig");
const store_mod = @import("ra8_chip").core.cpu.memory.store;

const Allocator = std.mem.Allocator;
pub const Port = port_mod.Port;
pub const Position = port_mod.Position;
pub const Core = port_mod.Core;
pub const Delta = delta_mod.Delta;
pub const Digest = digest_mod.Digest;
pub const DivergenceRefusal = digest_mod.DivergenceRefusal;

pub const Error = error{ NoWindow, OtherLine, Rebuilding, TrailDisarmed, NoProgress, CoreMissing };

/// How a slot is walked back and forth.
pub const Kind = enum(u8) {
    /// Guest memory, the core and the clocks only: raw swaps.
    ram_cpu,
    /// The slot touched the board or a part: section restore on undo,
    /// re-execution checked against the post digest on redo.
    complex,
};

/// One slot's window-side facts, parallel to the trail's own slot.
pub const Slot = struct {
    pre: Position,
    post: Position,
    core: Core,
    kind: Kind,
    delta: Delta,
    /// The post-state digest a re-executed complex slot must reproduce.
    digest: Digest = @splat(0),

    pub fn bytes(self: *const Slot) usize {
        return @sizeOf(Slot) + self.delta.bytes();
    }
};

pub const State = enum { empty, rebuilding, ready };

/// What the transport surfaces about the window.
pub const Status = struct {
    state: State,
    slots: usize,
    cursor: usize,
    used_bytes: usize,
    budget_bytes: usize,
    start: ?Position,
    end: ?Position,
    at: ?Position,
    progress: ?rebuild_mod.Progress,
};

pub const ReverseWindow = struct {
    allocator: Allocator,
    port: Port,
    recording: *trail_mod.Recording,
    trail: wtrail_mod.WindowTrail,
    budget: usize,
    slots: std.ArrayList(Slot) = .empty,
    /// The oldest live slot's index in `slots`.
    head: usize = 0,
    slot_bytes: usize = 0,
    /// The side image of the state at the cursor.
    image: std.ArrayList(u8) = .empty,
    /// The hot checkpoint: the whole save stream at or before the start.
    hot: []u8 = &.{},
    hot_at: ?Position = null,
    /// The window's end when it holds no slot: where it was planted.
    planted_at: ?Position = null,
    line: ?u32 = null,
    /// The last refused redo, kept until the next walk.
    refusal: ?DivergenceRefusal = null,
    /// The slot index the last refusal named.
    refused_slot: ?usize = null,
    rebuild: ?rebuild_mod.Job = null,

    pub fn init(allocator: Allocator, port: Port, recording: *trail_mod.Recording, store: *store_mod.Store, budget: usize) ReverseWindow {
        return .{
            .allocator = allocator,
            .port = port,
            .recording = recording,
            .trail = .init(allocator, recording, store, std.math.maxInt(usize)),
            .budget = budget,
        };
    }

    pub fn deinit(self: *ReverseWindow) void {
        self.drop();
        self.trail.deinit();
        self.slots.deinit(self.allocator);
        self.image.deinit(self.allocator);
        self.* = undefined;
    }

    /// Forgets every slot, the hot checkpoint and the line.
    pub fn drop(self: *ReverseWindow) void {
        while (self.count() > 0) self.evictOldest();
        self.slots.clearRetainingCapacity();
        self.head = 0;
        self.image.clearRetainingCapacity();
        self.allocator.free(self.hot);
        self.hot = &.{};
        self.hot_at = null;
        self.planted_at = null;
        self.line = null;
        self.refusal = null;
        self.refused_slot = null;
        if (self.rebuild) |job| if (job.base) |bytes| self.allocator.free(bytes);
        self.rebuild = null;
    }

    /// The machine now runs on `line`: a window built on another drops.
    pub fn noteLine(self: *ReverseWindow, line: u32) void {
        if (self.line) |own| if (own != line) self.drop();
    }

    /// Drops any future slots past the cursor: their deltas are freed,
    /// and the window's end retreats to the cursor's position.
    pub fn truncateFuture(self: *ReverseWindow) void {
        while (self.count() > self.cursor()) {
            const last_idx = self.slots.items.len - 1;
            const last = &self.slots.items[last_idx];
            self.slot_bytes -= last.bytes();
            last.delta.deinit(self.allocator);
            _ = self.slots.pop();
        }
        self.trail.truncateFuture();
    }

    /// Cuts the window at the fork point: drops future slots after cursor,
    /// and assigns the window to the new child branch.
    pub fn cutAtFork(self: *ReverseWindow, new_branch: u32) void {
        self.truncateFuture();
        self.line = new_branch;
        self.refusal = null;
        self.refused_slot = null;
    }

    pub fn count(self: *const ReverseWindow) usize {
        return self.slots.items.len - self.head;
    }

    pub fn cursor(self: *const ReverseWindow) usize {
        return self.trail.cursor;
    }

    pub fn slotAt(self: *ReverseWindow, index: usize) *Slot {
        return &self.slots.items[self.head + index];
    }

    pub fn usedBytes(self: *const ReverseWindow) usize {
        return self.trail.used_honest_bytes + self.slot_bytes;
    }

    /// Everything the window holds in memory: the budgeted trail and slots
    /// plus the hot checkpoint and the side image, which the byte budget
    /// does not bound.
    pub fn heldBytes(self: *const ReverseWindow) usize {
        return self.usedBytes() + self.hot.len + self.image.items.len;
    }

    pub fn ready(self: *const ReverseWindow) bool {
        return self.line != null and self.rebuild == null;
    }

    pub fn start(self: *ReverseWindow) ?Position {
        if (self.line == null) return null;
        if (self.count() == 0) return self.planted_at;
        return self.slotAt(0).pre;
    }

    pub fn end(self: *ReverseWindow) ?Position {
        if (self.line == null) return null;
        if (self.count() == 0) return self.planted_at;
        return self.slotAt(self.count() - 1).post;
    }

    /// The position the cursor stands on.
    pub fn at(self: *ReverseWindow) ?Position {
        if (self.line == null) return null;
        if (self.cursor() == self.count()) return self.end();
        return self.slotAt(self.cursor()).pre;
    }

    /// Whether `position` lies inside [start, end] on the window's line.
    pub fn covers(self: *ReverseWindow, position: Position) bool {
        if (!self.ready()) return false;
        const lo = self.start() orelse return false;
        const hi = self.end() orelse return false;
        const a = Position.order(lo, position) orelse return false;
        const b = Position.order(position, hi) orelse return false;
        return a != .gt and b != .gt;
    }

    pub fn status(self: *ReverseWindow) Status {
        const state: State = if (self.rebuild != null) .rebuilding else if (self.line != null) .ready else .empty;
        return .{
            .state = state,
            .slots = self.count(),
            .cursor = self.cursor(),
            .used_bytes = self.heldBytes(),
            .budget_bytes = self.budget,
            .start = self.start(),
            .end = self.end(),
            .at = self.at(),
            .progress = if (self.rebuild) |*job| job.progress() else null,
        };
    }

    /// Plants the hot checkpoint and an empty window at the live state.
    pub fn plant(self: *ReverseWindow) !void {
        const bytes = try self.port.fullBytes(self.allocator);
        errdefer self.allocator.free(bytes);
        var side: std.ArrayList(u8) = .empty;
        errdefer side.deinit(self.allocator);
        try self.port.sideInto(self.allocator, &side);
        self.allocator.free(self.hot);
        self.image.deinit(self.allocator);
        self.hot = bytes;
        self.image = side;
        self.hot_at = self.port.position();
        self.planted_at = self.hot_at;
        self.line = self.port.line();
    }

    /// Records one more slot at the window's end on `core`'s turn.
    pub fn extend(self: *ReverseWindow, core: Core) !void {
        if (self.rebuild != null) return Error.Rebuilding;
        try self.checkLine();
        if (self.cursor() != self.count()) return Error.NoWindow;
        // The step has moved the machine by the time a later stage fails,
        // so the window no longer describes it: it drops.
        errdefer self.drop();
        try record.recordSlot(self, core);
    }

    /// One slot back. False at the window start.
    pub fn undo(self: *ReverseWindow) !bool {
        try self.checkWalk();
        if (self.cursor() == 0) return false;
        const slot = self.slotAt(self.cursor() - 1);
        const pair = self.cpus();
        // A failure part way leaves cursor, image and machine apart.
        errdefer self.drop();
        _ = try self.trail.undoOne(pair[0] orelse return Error.CoreMissing, pair[1]);
        try slot.delta.flip(self.allocator, &self.image, false);
        try self.port.loadSide(self.image.items, slot.kind == .complex);
        return true;
    }

    /// One slot forward. False at the window end. A complex slot whose
    /// re-execution misses its digest refuses with HistoryDivergence,
    /// leaves the machine at the slot's pre-state and keeps the refusal.
    pub fn redo(self: *ReverseWindow) !bool {
        try self.checkWalk();
        if (self.cursor() == self.count()) return false;
        const index = self.cursor();
        const slot = self.slotAt(index);
        if (slot.kind == .complex) {
            record.reexecute(self, slot) catch |err| {
                if (err == error.HistoryDivergence) self.refused_slot = index;
                return err;
            };
            return true;
        }
        const pair = self.cpus();
        errdefer self.drop();
        _ = try self.trail.redoOne(pair[0] orelse return Error.CoreMissing, pair[1]);
        try slot.delta.flip(self.allocator, &self.image, true);
        try self.port.loadSide(self.image.items, false);
        return true;
    }

    /// Walks the cursor to slot `index` (0 is the start, count the end).
    pub fn walkTo(self: *ReverseWindow, index: usize) !void {
        if (index > self.count()) return Error.NoWindow;
        while (self.cursor() > index) _ = try self.undo();
        while (self.cursor() < index) _ = try self.redo();
    }

    /// Drops the oldest slot: the start moves forward, the hot checkpoint stays.
    pub fn evictOldest(self: *ReverseWindow) void {
        if (self.count() == 0) return;
        const oldest = self.slotAt(0);
        self.planted_at = oldest.post;
        self.slot_bytes -= oldest.bytes();
        oldest.delta.deinit(self.allocator);
        self.head += 1;
        self.trail.evictOldest();
        if (self.head > 64 and self.head * 2 > self.slots.items.len) {
            const live = self.slots.items[self.head..];
            std.mem.copyForwards(Slot, self.slots.items[0..live.len], live);
            self.slots.shrinkRetainingCapacity(live.len);
            self.head = 0;
        }
    }

    /// Evicts the oldest slots until the window fits its byte budget.
    pub fn enforceBudget(self: *ReverseWindow) void {
        while (self.count() > 1 and self.usedBytes() > self.budget) self.evictOldest();
    }

    fn checkWalk(self: *ReverseWindow) !void {
        if (self.rebuild != null) return Error.Rebuilding;
        try self.checkLine();
        self.refusal = null;
        self.refused_slot = null;
    }

    fn checkLine(self: *ReverseWindow) !void {
        const own = self.line orelse return Error.NoWindow;
        if (self.port.line() != own) {
            self.drop();
            return Error.OtherLine;
        }
    }

    pub fn cpus(self: *ReverseWindow) [2]?*port_mod.Cpu {
        return .{ self.port.cpu(.cpu0), self.port.cpu(.cpu1) };
    }
};
