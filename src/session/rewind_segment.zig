//! Silent segment decoding for smooth rewind: restore the machine at the
//! newest checkpoint or temporary hot checkpoint at or before the cursor,
//! replay forward unpaced and replaying (nothing is recorded again), and
//! keep the last scan of each presentation window of the segment as that
//! window's frame. A segment longer than 250 ms lays temporary in-memory
//! checkpoints every 100 ms on the way, so the next decode of the same
//! stretch starts from the nearest one instead of the pinned checkpoint.
const std = @import("std");
const frame_decoder = @import("history/frame_decoder.zig");
const temp_checkpoints = @import("history/temp_checkpoints.zig");
const smooth = @import("smooth_rewind.zig");
const line = @import("line.zig");

/// Decodes [start, end_ns] into the decoder's buckets. Returns the number
/// of windows that got a frame; nothing when no restore point or no scan
/// source is bound.
pub fn decode(engine: *smooth.SmoothRewindEngine, end_ns: u64) !usize {
    const scan = engine.scan orelse return 0;
    const session = engine.session;
    const decoder = &engine.decoder;
    try restoreStart(engine, end_ns);
    const start_ns = try session.now();
    if (end_ns <= start_ns) return 0;
    try decoder.prepareBuckets(start_ns, end_ns);
    const plan = try temp_checkpoints.TempCheckpoints.planSplit(engine.allocator, start_ns, end_ns);
    defer engine.allocator.free(plan);
    var next_plan: usize = 0;
    var next_bucket: usize = 0;
    session.setReplaying(true);
    defer session.setReplaying(false);
    const core = session.currentCore();
    var filled: usize = 0;
    while (line.inPast(session)) {
        const ended = try session.run(core, .cont);
        const now = try session.now();
        while (next_bucket < decoder.buckets.items.len and decoder.buckets.items[next_bucket].end_ns <= now) : (next_bucket += 1) {
            if (try scanInto(engine, scan, next_bucket)) filled += 1;
        }
        if (next_plan < plan.len and plan[next_plan] <= now) {
            try layTemp(engine, now);
            while (next_plan < plan.len and plan[next_plan] <= now) next_plan += 1;
        }
        if (now >= end_ns or ended != .count) break;
    }
    return filled;
}

/// Restores the nearest hot checkpoint at or before the target when one is
/// newer than the pinned checkpoint, else the pinned checkpoint itself.
fn restoreStart(engine: *smooth.SmoothRewindEngine, end_ns: u64) !void {
    if (engine.decoder.temp_checkpoints.nearestAtOrBeforeNs(end_ns)) |hot| {
        const history = engine.session.history orelse return error.NoHistory;
        try history.restoreBytes(hot.bytes);
        engine.session.stampLine();
        return;
    }
    var picture = (try engine.decoder.lookupRestorePicture(end_ns)) orelse return error.NoRestorePoint;
    defer picture.deinit(engine.allocator);
    const hook = engine.restore_hook orelse return error.NoRestorePoint;
    try hook.restore(picture.position);
}

fn scanInto(engine: *smooth.SmoothRewindEngine, scan: smooth.ScanSource, bucket: usize) !bool {
    const at = line.currentPosition(engine.session);
    var shot = (try scan.lastScan(engine.allocator, at)) orelse return false;
    defer shot.deinit(engine.allocator);
    const end = engine.decoder.buckets.items[bucket].end_ns;
    try engine.decoder.storeBucketFrame(.{
        .position = shot.position,
        .virtual_ns = end -| 1,
        .width = shot.width,
        .height = shot.height,
        .pixels = shot.pixels,
        .source = .decoded_segment,
    });
    return true;
}

/// A temporary checkpoint of the machine as it stands, from the same save
/// stream a recorded checkpoint carries.
fn layTemp(engine: *smooth.SmoothRewindEngine, now: u64) !void {
    const cp = engine.session.live.checkpoints orelse return;
    var staging: std.Io.Writer.Allocating = try .initCapacity(engine.allocator, 4096);
    defer staging.deinit();
    try cp.saveFn(cp.context, &staging.writer);
    try engine.decoder.temp_checkpoints.add(line.currentPosition(engine.session), now, staging.writer.buffered());
}
