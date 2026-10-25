//! Recording one reverse-window slot, and re-executing a recorded complex
//! slot against its digest (section 2.5).
//!
//! A slot is one replayed step on one core. Its guest-memory writes land
//! in the joined trail (trail.zig) and move into the window trail's slot;
//! the state beside guest memory is saved after the step and kept as an
//! XOR delta against the state before it. A slot that touched the board or
//! a part is complex, and its digest covers the side image after the step
//! and every write the step made, with the bytes each store write left.
//!
//! A structural barrier in a slot means the byte list no longer describes
//! the storage, so the window cannot reach back across it: every slot
//! before it is dropped and the hot checkpoint is planted again after it.
const std = @import("std");
const trail_mod = @import("trail.zig");
const slot_mod = @import("window_slot.zig");
const delta_mod = @import("window_delta.zig");
const digest_mod = @import("window_digest.zig");
const engine = @import("window_engine.zig");

const ReverseWindow = engine.ReverseWindow;
const Core = engine.Core;
const Digest = engine.Digest;

/// Runs and records one slot at the window's end.
pub fn recordSlot(w: *ReverseWindow, core: engine.Core) !void {
    if (!w.recording.attached) return engine.Error.TrailDisarmed;
    const cpu = w.port.cpu(core) orelse return engine.Error.CoreMissing;
    const pre_pos = w.port.position();
    const pre_arch = slot_mod.ArchState.capture(cpu);
    w.trail.startSlot(core, pre_pos, &pre_arch);
    const mark = w.trail.recording_mark;
    errdefer {
        w.trail.active_slot = false;
        discardFrom(w.recording, mark);
    }
    try w.port.step(core);
    const post_pos = w.port.position();
    if ((engine.Position.order(post_pos, pre_pos) orelse return engine.Error.OtherLine) != .gt) return engine.Error.NoProgress;

    var post_image: std.ArrayList(u8) = .empty;
    defer post_image.deinit(w.allocator);
    try w.port.sideInto(w.allocator, &post_image);
    var delta = try delta_mod.encode(w.allocator, w.image.items, post_image.items);
    errdefer delta.deinit(w.allocator);
    const records = w.recording.records[mark..w.recording.record_count];
    const kind: engine.Kind = if (delta.board or touchesPart(records)) .complex else .ram_cpu;
    const digest: Digest = if (kind == .complex) try slotDigest(w, post_image.items, records) else @splat(0);
    try w.slots.ensureUnusedCapacity(w.allocator, 1);
    const post_arch = slot_mod.ArchState.capture(cpu);
    try w.trail.endSlot(&post_arch, .ram_cpu);
    if (w.trail.slotAt(w.trail.count - 1).slot.kind == .barrier) {
        delta.deinit(w.allocator);
        delta = .{};
        while (w.count() > 0) w.evictOldest();
        // The barrier's own trail slot has no window slot beside it.
        while (w.trail.count > 0) w.trail.evictOldest();
        // A failed replant leaves no slot to describe the machine.
        errdefer w.drop();
        try w.plant();
        return;
    }
    w.slots.appendAssumeCapacity(.{ .pre = pre_pos, .post = post_pos, .core = core, .kind = kind, .delta = delta, .digest = digest });
    w.slot_bytes += w.slotAt(w.count() - 1).bytes();
    std.mem.swap(std.ArrayList(u8), &w.image, &post_image);
    w.enforceBudget();
}

/// Redoes a complex slot: the machine stands at its pre-state, so the slot
/// runs again and its fresh writes and side image must hash to the stored
/// digest. On a match the fresh pre-images replace the trail slot's bytes;
/// on a mismatch the fresh writes are rolled back, the pre-state sections
/// reloaded, and the refusal kept with the slot's position.
pub fn reexecute(w: *ReverseWindow, slot: *engine.Slot) !void {
    const payload = w.trail.slotAt(w.cursor());
    const mark = w.recording.record_count;
    errdefer rollback(w, mark) catch w.drop();
    try w.port.step(slot.core);
    var post_image: std.ArrayList(u8) = .empty;
    defer post_image.deinit(w.allocator);
    try w.port.sideInto(w.allocator, &post_image);
    const fresh = w.recording.records[mark..w.recording.record_count];
    const actual = try slotDigest(w, post_image.items, fresh);
    if (!std.mem.eql(u8, &actual, &slot.digest) or !sameShape(payload.byte_records, fresh)) {
        w.refusal = .{ .position = slot.pre, .expected_digest = slot.digest, .actual_digest = actual, .core = slot.core };
        return digest_mod.RedoError.HistoryDivergence;
    }
    for (payload.byte_records, fresh) |*kept, one| {
        w.recording.allocator.free(kept.data);
        kept.data = one.bytes.pre;
    }
    w.recording.record_count = mark;
    w.trail.cursor += 1;
    std.mem.swap(std.ArrayList(u8), &w.image, &post_image);
}

/// The post digest of one slot: the side image, then every write's place
/// and, for a store write, the bytes it left.
pub fn slotDigest(w: *ReverseWindow, image: []const u8, records: []const trail_mod.Record) !Digest {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(image);
    var buffer: [256]u8 = undefined;
    for (records) |one| switch (one) {
        .barrier => hasher.update("barrier"),
        .bytes => |b| {
            var head: [16]u8 = undefined;
            std.mem.writeInt(u32, head[0..4], b.base, .little);
            std.mem.writeInt(u64, head[4..12], b.offset, .little);
            std.mem.writeInt(u16, head[12..14], b.part orelse std.math.maxInt(u16), .little);
            std.mem.writeInt(u16, head[14..16], @intCast(@min(b.pre.len, std.math.maxInt(u16))), .little);
            hasher.update(&head);
            if (b.part != null) continue;
            const address: u32 = @intCast(b.base + b.offset);
            var done: usize = 0;
            while (done < b.pre.len) {
                const n = @min(buffer.len, b.pre.len - done);
                try w.trail.pureRead(address + @as(u32, @intCast(done)), buffer[0..n]);
                hasher.update(buffer[0..n]);
                done += n;
            }
        },
    };
    var full: [32]u8 = undefined;
    hasher.final(&full);
    return full[0..16].*;
}

fn touchesPart(records: []const trail_mod.Record) bool {
    for (records) |one| switch (one) {
        .barrier => return true,
        .bytes => |b| if (b.part != null) return true,
    };
    return false;
}

fn sameShape(kept: []const @import("window_trail.zig").ByteSwapRecord, fresh: []const trail_mod.Record) bool {
    if (kept.len != fresh.len) return false;
    for (kept, fresh) |a, one| switch (one) {
        .barrier => return false,
        .bytes => |b| if (a.base != b.base or a.offset != b.offset or a.part != b.part or a.data.len != b.pre.len) return false,
    };
    return true;
}

/// Puts back what the records from `mark` overwrote, newest first, frees
/// them, and reloads the side image the cursor stands on.
fn rollback(w: *ReverseWindow, mark: usize) !void {
    var i = w.recording.record_count;
    while (i > mark) {
        i -= 1;
        switch (w.recording.records[i]) {
            .barrier => {},
            .bytes => |b| if (b.part) |part| {
                if (part < w.recording.part_count) {
                    const restore = w.recording.parts[part];
                    restore.raw(restore.ctx, @truncate(b.offset), b.pre);
                }
            } else {
                const address: u32 = @intCast(b.base + b.offset);
                try w.trail.store.rawWrite(address, b.pre);
                w.trail.store.fan().notify(address, b.pre.len);
            },
        }
    }
    discardFrom(w.recording, mark);
    try w.port.loadSide(w.image.items, true);
}

/// Frees the records from `mark` on: they belong to no slot.
pub fn discardFrom(recording: *trail_mod.Recording, mark: usize) void {
    for (recording.records[mark..recording.record_count]) |*one| switch (one.*) {
        .bytes => |*b| b.deinit(recording.allocator),
        .barrier => {},
    };
    recording.record_count = mark;
}
