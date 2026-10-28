//! A reopened segment's recovery: every whole frame stays, a torn final
//! tail is truncated away through the storage, and a whole frame that
//! fails its length or CRC refuses the reopen.
const format = @import("format.zig");
const log_mod = @import("log.zig");
const Storage = @import("recorder.zig").Storage;

/// What a recovered segment answered.
pub const Recovery = struct {
    /// Where the whole frames end; a torn tail was truncated here.
    complete_end: u64,
    frames: usize,
    torn: bool,
};

fn countVisit(context: *usize, boundary: log_mod.Boundary) void {
    _ = boundary;
    context.* += 1;
}

/// Scans a segment's bytes the way a reopen does: every whole frame is
/// kept, a torn final tail is truncated away through the storage, and a
/// whole frame that fails its length or CRC refuses the reopen. The
/// caller owns reading the bytes; the recorder only ever asks the
/// storage to shorten them.
pub fn recoverSegment(bytes: []const u8, storage: Storage) (format.Error || anyerror)!Recovery {
    var frames: usize = 0;
    const hit = try log_mod.scan(bytes, &frames, countVisit);
    if (hit.torn) {
        try storage.truncate(storage.context, hit.complete_end);
        return .{ .complete_end = hit.complete_end, .frames = hit.frames, .torn = true };
    }
    return .{ .complete_end = hit.complete_end, .frames = hit.frames, .torn = false };
}
