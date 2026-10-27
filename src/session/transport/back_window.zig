//! Building the reverse window for a backward step (section 2.5): a run
//! that was not recorded live leaves no window, so the first reverse step
//! restores the nearest checkpoint, replays to the round before the cursor
//! and records the rest, once. The step and the ones after it then walk the
//! window instead of replaying from a checkpoint each time.
const std = @import("std");
const back_mod = @import("back.zig");
const rebuild = @import("../history/window_rebuild.zig");
const engine = @import("../history/window_engine.zig");
const trail = @import("../history/trail.zig");
const transport_mod = @import("transport.zig");

const Transport = transport_mod.Transport;
const Job = transport_mod.Job;

/// Builds the window up to the job's cursor from the checkpoint the machine
/// stands at, leaving the machine at the cursor and the job on the window.
/// False when no window can be built (none attached, a second core, the
/// log's beginning, a cursor the replay does not land on); the machine is
/// then somewhere on the replay and the caller restores the base again.
pub fn build(self: *Transport, job: *Job, back: *back_mod.Back) bool {
    back.windowed = true;
    const w = self.session.window orelse return false;
    if (self.session.window_driver == null or back.start) return false;
    if (w.port.cpu(.cpu1) != null) return false;
    const grid = self.session.grid orelse return false;
    const core: trail.Core = if (job.core == .cpu0) .cpu0 else .cpu1;
    const cursor = back.cursor;
    // The window starts a round before the cursor: that is the reach of
    // the steps it serves, and the replay it costs stays one round long.
    const start: ?engine.Position = if (cursor.r > grid.at.r + 1)
        .{ .branch = cursor.branch, .r = cursor.r - 1, .phase = .cpu0, .o = 0, .gap = .retired }
    else
        null;
    rebuild.run(w, .{ .base = .current, .core = core, .start = start, .end = cursor }) catch {
        w.drop();
        return false;
    };
    const end = w.end() orelse return false;
    if (w.count() == 0 or !std.meta.eql(end, cursor)) {
        w.drop();
        return false;
    }
    back.base = .{ .window = .{ .position = cursor, .dir = .undo, .slots = 1 } };
    return true;
}
