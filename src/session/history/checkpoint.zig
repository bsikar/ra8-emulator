//! The session's checkpoint policy: every N closed rounds the run's save
//! stream lands in the recorder's object space and a Checkpoint record
//! names it (RA8EMU-1196). The session arms the controller on its
//! boundary; the run loop only offers the closed round.
const std = @import("std");
const recorder_mod = @import("recorder.zig");
const record = @import("record.zig");
const scheduler = @import("ra8_chip").core.scheduler;

/// One session's checkpoint policy and sink. The application binds the
/// serializer (the run's own save stream, the bytes a state file carries)
/// and the recorder; the policy checkpoints every N closed rounds.
pub const Checkpoint = struct {
    context: *anyopaque,
    /// Writes the whole machine's save stream into `writer`.
    saveFn: *const fn (context: *anyopaque, writer: *std.Io.Writer) anyerror!void,
    /// The recorder the object bytes and the Checkpoint record reach.
    recorder: *recorder_mod.Recorder,
    /// The run's saved scheduler state; the record's position is the
    /// state's position at the boundary the hook offers.
    saved: *const scheduler.State,
    /// One checkpoint every N closed rounds; zero disables.
    every: u32 = 64,
    /// The next checkpoint's record id.
    next_id: u32 = 0,
    /// The bytes checkpoints may take on the volume; zero runs the
    /// cadence unprojected. The application fills it from its share
    /// math (the checkpoints partition, 60% of the ephemeral share).
    object_cap: u64 = 0,
    /// The last landed checkpoint's object size, the projection's stand
    /// in for the next one.
    last_size: u64 = 0,

    /// Offers a closed round to the policy. On every Nth round the save
    /// stream goes to the recorder's object space first, then the
    /// Checkpoint record stages behind it, so the record never names an
    /// object the storage does not hold (object-before-log).
    pub fn fire(self: *Checkpoint, round: u64) anyerror!void {
        if (self.every == 0 or round == 0 or round % self.every != 0) return;
        // The budget's relief order, the controller's share of it: the
        // orphans and frames steps belong to the host's prune (the
        // recorder cannot scan its object space), so the controller
        // applies the checkpoints step, thinning the cadence when the
        // last checkpoint's size again would put the objects past the
        // checkpoints partition, and the stop step, refusing when one
        // checkpoint alone cannot fit whatever cadence runs.
        if (self.object_cap != 0) {
            if (self.last_size > self.object_cap) return error.HistoryFull;
            if (self.recorder.object_bytes + self.last_size > self.object_cap) {
                self.every = std.math.mul(u32, self.every, 2) catch std.math.maxInt(u32);
                return;
            }
        }
        var staging: std.Io.Writer.Allocating = try .initCapacity(self.recorder.gpa, 4096);
        defer staging.deinit();
        try self.saveFn(self.context, &staging.writer);
        const bytes = staging.writer.buffered();
        const header: record.Header = .{ .position = self.saved.at, .seq = 0 };
        try self.recorder.checkpoint(header, self.next_id, bytes);
        self.next_id += 1;
        self.last_size = bytes.len;
        // The record commits at once: object-before-log's record half, so
        // a crash never leaves a durable object without its naming record.
        try self.recorder.commit(0);
    }

    /// The boundary-facing hook.
    pub fn hook(context: *anyopaque, round: u64) anyerror!void {
        const self: *Checkpoint = @ptrCast(@alignCast(context));
        try self.fire(round);
    }
};
