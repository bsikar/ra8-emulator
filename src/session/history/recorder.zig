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
const budget = @import("budget.zig");

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

pub const Error = error{ OutOfMemory, WriteFailed, NoObjects } || format.Error;

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
/// The object space a checkpoint's saved machine reaches, as the
/// application fills it. `put` stores the bytes under the name the
/// recorder chose; `sync` makes them durable. Object-before-log is the
/// order this module proves: a checkpoint's bytes are durable here
/// before its record can become visible in the log, so a reader never
/// follows a record to an object the storage does not hold.
pub const Objects = struct {
    context: *anyopaque,
    put: *const fn (context: *anyopaque, name: []const u8, bytes: []const u8) anyerror!void,
    sync: *const fn (context: *anyopaque) anyerror!void,
};

/// The disk-side budget the application fills: the share this history's
/// bytes must stay under on the volume, and the fresh free-space read the
/// recorder asks for before each commit and checkpoint. Null keeps an
/// unmeasured history, the way an in-RAM session runs. The share and the
/// floor come from the application's budget math; the free-space read
/// crosses as a callback because session never touches the host.
pub const Budget = struct {
    context: *anyopaque,
    /// Bytes the volume has free right now, read fresh per check.
    free: *const fn (context: *anyopaque) anyerror!u64,
    /// This history's share of the volume.
    cap: u64,
    /// The free space the volume must still hold after the bytes go out.
    floor: u64,
    /// The relief the application supplies for a refused commit or
    /// checkpoint: it runs once when the check refuses, before the
    /// refusal stands, so the retry can land. Null keeps a history
    /// that refuses without relief.
    relief: ?*const fn (context: *anyopaque) anyerror!void = null,
};

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
    /// The object space checkpoints write through, as the application
    /// fills it; a recorder without one refuses checkpoints.
    objects: ?Objects = null,
    /// The disk-side budget, as the application fills it; null is
    /// unmeasured, and nothing is refused.
    disk: ?Budget = null,
    /// Bytes the object space holds for this segment's checkpoints, part
    /// of what the budget counts as used.
    object_bytes: u64 = 0,
    /// The pressure the last disk check answered with; the application
    /// reads it to warn at 80 percent before the stop at 100.
    last_pressure: budget.Pressure = .normal,

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

    /// Pins one checkpoint: writes the saved machine's bytes into the
    /// object space under the 128-bit truncated SHA-256 of the bytes,
    /// makes them durable with a sync, and only then stages the
    /// Checkpoint record, so the record never names an object the
    /// storage does not hold yet. The staged record leaves at the next
    /// commit, with whatever frames share it.
    pub fn checkpoint(self: *Recorder, header: record.Header, id: u32, bytes: []const u8) anyerror!void {
        const objects = self.objects orelse return Error.NoObjects;
        if (self.disk) |watch| {
            _ = try self.checkDisk(watch, self.committed_bytes + self.object_bytes, bytes.len);
        }
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        var name: [32]u8 = undefined;
        for (digest[0..16], 0..) |byte, i| {
            _ = std.fmt.bufPrint(name[i * 2 ..][0..2], "{x:0>2}", .{byte}) catch unreachable;
        }
        try objects.put(objects.context, &name, bytes);
        try objects.sync(objects.context);
        var staging: std.Io.Writer.Allocating = try .initCapacity(self.gpa, 64);
        defer staging.deinit();
        try record.encodeCheckpoint(&staging.writer, header, .{ .id = id, .object = digest[0..16].* });
        const payload = staging.writer.buffered();
        try format.encode(&self.staging.writer, @backingInt(record.Kind.checkpoint), payload);
        self.log.pending_bytes += format.header_len + payload.len;
        self.object_bytes += bytes.len;
    }

    /// The disk-side check both a commit and a checkpoint run: one
    /// fresh free-space read, and on a refusal the application's
    /// relief, once, then one re-check whose answer stands. The relief
    /// crosses as a callback the same way the free-space read does,
    /// because session never touches the host.
    fn checkDisk(self: *Recorder, watch: Budget, used: u64, additional: u64) anyerror!budget.Pressure {
        const free = try watch.free(watch.context);
        if (budget.checkCommit(used, additional, watch.cap, free, watch.floor)) |answer| {
            self.last_pressure = answer;
            return answer;
        } else |err| {
            const relieve = watch.relief orelse return err;
            try relieve(watch.context);
            const relieved = try watch.free(watch.context);
            self.last_pressure = try budget.checkCommit(used, additional, watch.cap, relieved, watch.floor);
            return self.last_pressure;
        }
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
    /// flush, and restarts both thresholds on the caller's clock. With a
    /// disk budget filled, a commit whose bytes the volume or the share
    /// cannot take refuses with error.HistoryFull first, and its bytes
    /// stay staged for a later retry.
    pub fn commit(self: *Recorder, now_ns: u64) anyerror!void {
        if (self.disk) |watch| {
            if (self.log.pending_bytes > 0) {
                _ = try self.checkDisk(watch, self.committed_bytes + self.object_bytes, self.log.pending_bytes);
            }
        }
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
