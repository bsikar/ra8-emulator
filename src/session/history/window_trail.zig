//! Bounded reverse window trail buffer and exact undo/redo engine (Section 2.5).
//!
//! Reuses the existing write observer and trail machinery from `trail.zig`.
//! Memory writes are tracked without a parallel observer. Undo swaps pre/post
//! in-place and redo swaps back, invalidating code caches on every restored range.
//! Accounting is in honest bytes (headers + payload), evicting oldest slots
//! first when exceeding budget.
const std = @import("std");
const Allocator = std.mem.Allocator;
const store_mod = @import("ra8_chip").core.cpu.memory.store;
const cpu_mod = @import("ra8_chip").core.cpu.cpu;
const trail_mod = @import("trail.zig");
const slot_mod = @import("window_slot.zig");
const digest_mod = @import("window_digest.zig");
const micro_mod = @import("micro_checkpoint.zig");

pub const Position = slot_mod.Position;
pub const Core = slot_mod.Core;
pub const SlotKind = slot_mod.SlotKind;
pub const WindowSlot = slot_mod.WindowSlot;
pub const RegDiff = slot_mod.RegDiff;
pub const ArchState = slot_mod.ArchState;

pub const ByteSwapRecord = struct {
    base: u32,
    offset: u64,
    part: ?u16,
    data: []u8,
};

pub const SlotPayload = struct {
    slot: WindowSlot,
    diffs: []RegDiff,
    byte_records: []ByteSwapRecord,
    micro_bytes: []u8 = &.{},
};

pub const WindowTrail = struct {
    allocator: Allocator,
    recording: *trail_mod.Recording,
    store: *store_mod.Store,
    capacity_bytes: usize,
    used_honest_bytes: usize = 0,
    slots: []SlotPayload = &.{},
    head: usize = 0,
    count: usize = 0,
    cursor: usize = 0,
    recording_mark: usize = 0,
    pre_state: ArchState = .{},
    active_slot: bool = false,
    active_pos: Position = undefined,
    active_core: Core = .cpu0,

    pub fn init(
        allocator: Allocator,
        recording: *trail_mod.Recording,
        store: *store_mod.Store,
        capacity_bytes: usize,
    ) WindowTrail {
        return .{
            .allocator = allocator,
            .recording = recording,
            .store = store,
            .capacity_bytes = capacity_bytes,
        };
    }

    pub fn deinit(self: *WindowTrail) void {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const idx = (self.head + i) % self.slots.len;
            self.freePayload(self.slots[idx]);
        }
        if (self.slots.len > 0) self.allocator.free(self.slots);
        self.* = undefined;
    }

    pub fn startSlot(self: *WindowTrail, core: Core, pos: Position, pre: *const ArchState) void {
        self.recording_mark = self.recording.record_count;
        self.pre_state = pre.*;
        self.active_pos = pos;
        self.active_core = core;
        self.active_slot = true;
    }

    const Collected = struct {
        records: []ByteSwapRecord,
        payload_bytes: usize,
        kind: SlotKind,
    };

    fn collectByteRecords(self: *WindowTrail, base_kind: SlotKind) !Collected {
        const new_records = self.recording.records[self.recording_mark..self.recording.record_count];
        var byte_count: usize = 0;
        var has_part: bool = false;
        var has_barrier: bool = false;

        for (new_records) |r| switch (r) {
            .bytes => |b| {
                byte_count += 1;
                if (b.part != null) has_part = true;
            },
            .barrier => has_barrier = true,
        };

        const resolved_kind: SlotKind = if (has_barrier)
            .barrier
        else if (has_part or base_kind == .complex)
            .complex
        else
            base_kind;

        const byte_records = try self.allocator.alloc(ByteSwapRecord, byte_count);
        errdefer self.allocator.free(byte_records);

        var total_payload_bytes: usize = 0;
        var b_idx: usize = 0;
        for (new_records) |r| switch (r) {
            .bytes => |b| {
                byte_records[b_idx] = .{
                    .base = b.base,
                    .offset = b.offset,
                    .part = b.part,
                    .data = b.pre,
                };
                total_payload_bytes += b.pre.len;
                b_idx += 1;
            },
            .barrier => {},
        };
        return .{
            .records = byte_records,
            .payload_bytes = total_payload_bytes,
            .kind = resolved_kind,
        };
    }

    pub fn endSlot(self: *WindowTrail, post: *const ArchState, kind: SlotKind) !void {
        return self.endSlotWithMicro(post, kind, &.{});
    }

    pub fn endSlotWithMicro(
        self: *WindowTrail,
        post: *const ArchState,
        kind: SlotKind,
        micro_bytes: []const u8,
    ) !void {
        if (!self.active_slot) return;
        self.active_slot = false;

        if (!self.recording.healthy()) return error.TrailPoisoned;

        self.truncateFuture();

        const base_kind = if (micro_bytes.len > 0) .complex else kind;
        const collected = try self.collectByteRecords(base_kind);
        const byte_records = collected.records;
        errdefer self.allocator.free(byte_records);

        var diff_buf: [slot_mod.reg_tag_count]RegDiff = undefined;
        const diff_count = slot_mod.diffArch(&self.pre_state, post, &diff_buf);
        const diffs = try self.allocator.alloc(RegDiff, diff_count);
        errdefer self.allocator.free(diffs);
        @memcpy(diffs, diff_buf[0..diff_count]);

        const micro_copy: []u8 = if (micro_bytes.len > 0)
            try self.allocator.dupe(u8, micro_bytes)
        else
            @constCast(&.{});
        errdefer if (micro_copy.len > 0) self.allocator.free(micro_copy);

        const post_digest = if (collected.kind == .complex or micro_bytes.len > 0)
            digest_mod.computeDigest(post, micro_bytes)
        else
            @as([16]u8, @splat(0));

        const honest_bytes = @sizeOf(SlotPayload) +
            diffs.len * @sizeOf(RegDiff) +
            byte_records.len * @sizeOf(ByteSwapRecord) +
            collected.payload_bytes +
            micro_copy.len;

        while (self.count > 0 and self.used_honest_bytes + honest_bytes > self.capacity_bytes) {
            self.evictOldest();
        }

        try self.ensureCapacity();

        // All allocations succeeded: safely transfer ownership of b.pre from recording
        self.recording.record_count = self.recording_mark;

        const insert_idx = (self.head + self.count) % self.slots.len;
        self.slots[insert_idx] = .{
            .slot = .{
                .position = self.active_pos,
                .kind = collected.kind,
                .core = self.active_core,
                .diff_count = @intCast(diffs.len),
                .byte_count = @intCast(byte_records.len),
                .honest_bytes = honest_bytes,
                .post_digest = post_digest,
            },
            .diffs = diffs,
            .byte_records = byte_records,
            .micro_bytes = micro_copy,
        };
        self.count += 1;
        self.cursor = self.count;
        self.used_honest_bytes += honest_bytes;
    }

    pub fn undoOne(self: *WindowTrail, cpu: *cpu_mod.Cpu, peer: ?*cpu_mod.Cpu) !bool {
        return self.undoOneWithBoard(cpu, peer, null);
    }

    pub fn undoOneWithBoard(self: *WindowTrail, cpu: *cpu_mod.Cpu, peer: ?*cpu_mod.Cpu, board: anytype) !bool {
        if (self.cursor == 0) return false;
        const target_idx = self.cursor - 1;
        const payload = self.slotAt(target_idx);

        if (payload.slot.kind == .barrier) {
            return error.BarrierReached;
        }

        self.cursor = target_idx;
        var i = payload.byte_records.len;
        while (i > 0) {
            i -= 1;
            try self.undoMemoryRecord(&payload.byte_records[i]);
        }

        if (payload.micro_bytes.len > 0 and @TypeOf(board) != @TypeOf(null)) {
            const b = if (@typeInfo(@TypeOf(board)) == .optional) (board orelse return error.RequiresBoard) else board;
            try micro_mod.restoreBytes(payload.micro_bytes, b);
        }

        const target = if (peer) |p| (if (payload.slot.core == .cpu0) cpu else p) else cpu;
        var arch = ArchState.capture(target);
        slot_mod.swapDiffInState(payload.diffs, &arch);
        arch.restore(target);
        return true;
    }

    pub fn redoOne(self: *WindowTrail, cpu: *cpu_mod.Cpu, peer: ?*cpu_mod.Cpu) !bool {
        return self.redoOneWithBoard(cpu, peer, null, null);
    }

    pub fn redoOneWithBoard(
        self: *WindowTrail,
        cpu: *cpu_mod.Cpu,
        peer: ?*cpu_mod.Cpu,
        board: anytype,
        re_exec_fn: ?*const fn () anyerror!void,
    ) !bool {
        if (self.cursor >= self.count) return false;
        const payload = self.slotAt(self.cursor);

        if (payload.slot.kind == .complex) {
            const re_exec = re_exec_fn orelse return error.RequiresReExecution;
            if (@TypeOf(board) == @TypeOf(null)) return error.RequiresReExecution;
            const b = if (@typeInfo(@TypeOf(board)) == .optional) (board orelse return error.RequiresReExecution) else board;
            _ = b;
            try re_exec();
            const target = if (peer) |p| (if (payload.slot.core == .cpu0) cpu else p) else cpu;
            const post_arch = ArchState.capture(target);
            try digest_mod.verifyRedoDigest(
                payload.slot.post_digest,
                &post_arch,
                payload.micro_bytes,
                payload.slot.position,
                payload.slot.core,
                null,
            );
            self.cursor += 1;
            return true;
        }

        if (payload.slot.kind == .barrier) {
            return error.RequiresReExecution;
        }

        for (payload.byte_records) |*rec| {
            try self.redoMemoryRecord(rec);
        }

        const target = if (peer) |p| (if (payload.slot.core == .cpu0) cpu else p) else cpu;
        var arch = ArchState.capture(target);
        slot_mod.swapDiffInState(payload.diffs, &arch);
        arch.restore(target);
        self.cursor += 1;
        return true;
    }

    pub fn slotAt(self: *WindowTrail, idx: usize) *SlotPayload {
        return &self.slots[(self.head + idx) % self.slots.len];
    }

    fn undoMemoryRecord(self: *WindowTrail, rec: *ByteSwapRecord) !void {
        if (rec.part) |part_idx| {
            if (part_idx < self.recording.part_count) {
                const part = self.recording.parts[part_idx];
                part.raw(part.ctx, @truncate(rec.offset), rec.data);
            }
            return;
        }
        try self.swapMemoryChunks(rec);
    }

    fn redoMemoryRecord(self: *WindowTrail, rec: *ByteSwapRecord) !void {
        if (rec.part != null) return error.RequiresReExecution;
        try self.swapMemoryChunks(rec);
    }

    fn swapMemoryChunks(self: *WindowTrail, rec: *ByteSwapRecord) !void {
        const addr: u32 = @intCast(rec.base + rec.offset);
        var chunk_offset: usize = 0;
        var temp_buf: [256]u8 = undefined;

        while (chunk_offset < rec.data.len) {
            const chunk_len = @min(rec.data.len - chunk_offset, temp_buf.len);
            const chunk_addr = addr + @as(u32, @intCast(chunk_offset));
            const chunk_slice = rec.data[chunk_offset..][0..chunk_len];
            const temp = temp_buf[0..chunk_len];

            try self.pureRead(chunk_addr, temp);
            try self.store.rawWrite(chunk_addr, chunk_slice);
            @memcpy(chunk_slice, temp);
            self.store.fan().notify(chunk_addr, chunk_len);

            chunk_offset += chunk_len;
        }
    }

    pub fn pureRead(self: *WindowTrail, address: u32, into: []u8) !void {
        if (into.len == 0) return;
        if (self.store.port) |*port| if (port.geometry.locate(address, into.len)) |hit| {
            switch (hit.kind) {
                .ospi => if (!port.flash.read(hit.offset, into)) return error.Unmapped,
                .sdram => @memcpy(into, port.sdram[hit.offset..][0..into.len]),
            }
            return;
        };
        const loc = self.store.locate(address, into.len) orelse return error.Unmapped;
        @memcpy(into, loc.bytes);
    }

    fn truncateFuture(self: *WindowTrail) void {
        while (self.count > self.cursor) {
            const last_idx = (self.head + self.count - 1) % self.slots.len;
            const last = &self.slots[last_idx];
            self.used_honest_bytes -= last.slot.honest_bytes;
            self.freePayload(last.*);
            self.count -= 1;
        }
    }

    pub fn evictOldest(self: *WindowTrail) void {
        if (self.count == 0) return;
        const oldest = &self.slots[self.head];
        self.used_honest_bytes -= oldest.slot.honest_bytes;
        self.freePayload(oldest.*);
        self.head = (self.head + 1) % self.slots.len;
        self.count -= 1;
        if (self.cursor > 0) self.cursor -= 1;
    }

    fn freePayload(self: *WindowTrail, p: SlotPayload) void {
        for (p.byte_records) |r| self.recording.allocator.free(r.data);
        if (p.byte_records.len > 0) self.allocator.free(p.byte_records);
        if (p.diffs.len > 0) self.allocator.free(p.diffs);
        if (p.micro_bytes.len > 0) self.allocator.free(p.micro_bytes);
    }

    fn ensureCapacity(self: *WindowTrail) !void {
        if (self.count < self.slots.len) return;
        const new_cap = if (self.slots.len == 0) 16 else self.slots.len * 2;
        const new_slots = try self.allocator.alloc(SlotPayload, new_cap);
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            new_slots[i] = self.slots[(self.head + i) % self.slots.len];
        }
        if (self.slots.len > 0) self.allocator.free(self.slots);
        self.slots = new_slots;
        self.head = 0;
    }
};
