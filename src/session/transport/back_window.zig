//! Building the reverse window for a backward step (section 2.5): a run
//! that was not recorded live leaves no window, so the first reverse step
//! restores the nearest checkpoint, replays to the bounded span before the
//! cursor and records up to the cursor in slices. The step and the ones
//! after it then walk the window across both cores instead of replaying
//! from a checkpoint each time.
const std = @import("std");
const back_mod = @import("back.zig");
const rebuild = @import("../history/window_rebuild.zig");
const engine = @import("../history/window_engine.zig");
const trail = @import("../history/trail.zig");
const transport_mod = @import("transport.zig");

const Transport = transport_mod.Transport;
const Job = transport_mod.Job;

const rebuild_slice_slots: usize = 256;

/// Starts a sliced window rebuild from the restored checkpoint up to the
/// job's cursor across single-core and dual-core machines alike.
pub fn beginBuild(self: *Transport, job: *Job, back: *back_mod.Back) bool {
    back.windowed = true;
    const w = self.session.window orelse return false;
    if (self.session.window_driver == null or back.start) return false;
    const grid = self.session.grid orelse return false;
    const core: trail.Core = if (job.core == .cpu0) .cpu0 else .cpu1;
    const cursor = back.cursor;
    const chunk: u64 = if (self.session.live.boundary) |edge| @max(1, edge.chunk) else 64;
    const dual = w.port.cpu(.cpu1) != null;
    const target_slots: u64 = @min(4096, @max(128, w.budget / (if (dual) @as(usize, 256) else 128)));
    const start = startOf(grid.at, cursor, chunk, target_slots);
    rebuild.begin(w, .{ .base = .current, .core = core, .start = start, .end = cursor }) catch {
        w.drop();
        return false;
    };
    back.rebuilding = true;
    return true;
}

fn startOf(base: engine.Position, cursor: engine.Position, chunk: u64, target_slots: u64) ?engine.Position {
    if (chunk <= 512) {
        const span: u64 = @min(16, @max(2, target_slots / chunk));
        return if (cursor.r > base.r + span)
            .{ .branch = cursor.branch, .r = cursor.r - span, .phase = .cpu0, .o = 0, .gap = .retired }
        else
            null;
    }
    if (cursor.phase == .cpu0 and cursor.o > target_slots) {
        const start_pos: engine.Position = .{ .branch = cursor.branch, .r = cursor.r, .phase = .cpu0, .o = @intCast(cursor.o - target_slots), .gap = .retired };
        return if ((engine.Position.order(base, start_pos) orelse .gt) == .lt) start_pos else null;
    }
    if (cursor.r > base.r) {
        const tail_o: u32 = if (chunk > target_slots) @intCast(chunk - target_slots) else 0;
        const start_pos: engine.Position = .{ .branch = cursor.branch, .r = cursor.r - 1, .phase = .cpu0, .o = tail_o, .gap = .retired };
        return if ((engine.Position.order(base, start_pos) orelse .gt) == .lt) start_pos else null;
    }
    return null;
}

/// Drives one bounded slice of an active window rebuild. Returns true while
/// the rebuild is still active or has just handed the job over to `.window`;
/// returns false if the rebuild failed and the caller should fall back.
pub fn stepBuild(self: *Transport, back: *back_mod.Back) bool {
    const w = self.session.window orelse {
        back.rebuilding = false;
        back.restored = false;
        return false;
    };
    const done = rebuild.slice(w, rebuild_slice_slots) catch {
        w.drop();
        back.rebuilding = false;
        back.restored = false;
        return false;
    };
    if (!done) return true;
    back.rebuilding = false;
    const end = w.end() orelse {
        w.drop();
        back.restored = false;
        return false;
    };
    if (w.count() == 0 or !std.meta.eql(end, back.cursor)) {
        w.drop();
        back.restored = false;
        return false;
    }
    back.base = .{ .window = .{ .position = back.cursor, .dir = .undo, .slots = 1 } };
    return true;
}
