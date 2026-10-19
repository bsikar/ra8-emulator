//! The persistent history's recorder: the spine that turns a session's
//! boundary landings into event-log frames on the application's storage.
//!
//! Session stays std-only: the recorder never opens a file itself. The
//! application fills a Storage with the three host operations the spine
//! needs (append, flush, truncate) and bridges it to the history's log
//! space (src/host/history). Frames are staged through log.zig's group
//! commit on the caller's clock, and a commit releases the staged bytes
//! to the storage as one append plus one flush, so the storage is never
//! told about a frame in part. Object-before-log durability is the
//! checkpoint's job and arrives with the checkpoint work: this spine
//! records boundary and intervention frames, whose payload lives in the
//! log itself.
//!
//! A reopened segment recovers through log.zig's scan: the whole frames
//! stay, a torn final tail is truncated away through the storage, and a
//! whole frame that fails its length or CRC refuses the reopen.
const std = @import("std");
const format = @import("format.zig");
const log_mod = @import("log.zig");
const record = @import("record.zig");

/// The host storage the recorder writes through, as the application
/// fills it. Session calls these and nothing else about the host.
pub const Storage = struct {
    context: *anyopaque,
    append: *const fn (context: *anyopaque, bytes: []const u8) anyerror!void,
    flush: *const fn (context: *anyopaque) anyerror!void,
    truncate: *const fn (context: *anyopaque, len: u64) anyerror!void,
};

/// What a recovered segment answered.
pub const Recovery = struct {
    /// Where the whole frames end; a torn tail was truncated here.
    complete_end: u64,
    frames: usize,
    torn: bool,
};

pub const Error = error{ OutOfMemory, WriteFailed } || format.Error;

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

/// The recorder over one log segment.
pub const Recorder = struct {
    gpa: std.mem.Allocator,
    storage: Storage,
    log: log_mod.Log,
    /// The staged bytes between commits; a commit hands them to the
    /// storage as one append and empties it. Heap-owned, so the log's
    /// writer pointer stays valid wherever the recorder itself lives.
    staging: *std.Io.Writer.Allocating,
    /// Bytes the storage holds for this segment so far.
    committed_bytes: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, storage: Storage, policy: log_mod.CommitPolicy) Error!Recorder {
        const staging = try gpa.create(std.Io.Writer.Allocating);
        errdefer gpa.destroy(staging);
        staging.* = try std.Io.Writer.Allocating.initCapacity(gpa, 4096);
        return .{
            .gpa = gpa,
            .storage = storage,
            .log = .{ .writer = &staging.writer, .policy = policy },
            .staging = staging,
        };
    }

    pub fn deinit(self: *Recorder) void {
        self.staging.deinit();
        self.gpa.destroy(self.staging);
    }

    /// Records an external event at the boundary where it landed.
    pub fn recordBoundary(self: *Recorder, header: record.Header, boundary: record.Boundary) anyerror!void {
        try self.stage(@backingInt(record.Kind.boundary), header, boundary.what, boundary.body);
    }

    /// Records a host-originated mutation that crossed a dispatching
    /// boundary.
    pub fn recordIntervention(self: *Recorder, header: record.Header, intervention: record.Intervention) anyerror!void {
        try self.stage(@backingInt(record.Kind.intervention), header, intervention.what, intervention.body);
    }

    fn stage(self: *Recorder, kind: u16, header: record.Header, what: anytype, body: []const u8) anyerror!void {
        var staging: std.Io.Writer.Allocating = try .initCapacity(self.gpa, 64 + body.len);
        defer staging.deinit();
        try record.encodeBodied(&staging.writer, header, @backingInt(what), body);
        const payload = staging.writer.buffered();
        try format.encode(&self.staging.writer, kind, payload);
        self.log.pending_bytes += format.header_len + payload.len;
    }

    /// Commits at the first of the policy's two thresholds, on the
    /// caller's clock.
    pub fn maybeCommit(self: *Recorder, now_ns: u64) anyerror!void {
        if (self.log.shouldCommit(now_ns) == .no) return;
        try self.commit(now_ns);
    }

    /// Hands the log its first time sample without committing.
    pub fn observe(self: *Recorder, now_ns: u64) void {
        self.log.observe(now_ns);
    }

    /// Releases every staged byte to the storage as one append plus one
    /// flush, and restarts both thresholds on the caller's clock.
    pub fn commit(self: *Recorder, now_ns: u64) anyerror!void {
        try self.log.commit(now_ns);
        const bytes = self.staging.writer.buffered();
        if (bytes.len == 0) return;
        try self.storage.append(self.storage.context, bytes);
        try self.storage.flush(self.storage.context);
        self.committed_bytes += bytes.len;
        self.staging.writer.end = 0;
    }

    /// Bytes staged but not yet in the storage's hands.
    pub fn pendingBytes(self: *const Recorder) usize {
        return self.staging.writer.buffered().len;
    }
};
