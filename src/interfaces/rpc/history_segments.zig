//! The committed log of a disk history across every segment its lines wrote
//! (time-travel design section 9): each branch's records live in their own
//! `events-B-S` segments, and a reader that plans a seek or replays a line
//! needs all of them, the ancestors' prefixes included.
//!
//! Only whole frames are read: a segment's torn tail (a commit a crash cut
//! short) stops at its last complete frame, so the segments concatenate
//! into one frame stream the session's scanners walk. Records carry their
//! own canonical positions, so the order segments are joined in does not
//! matter to the readers, which sort by position.
const std = @import("std");
const history = @import("ra8_host").history;
const session_log = @import("ra8_session").history_log;
const session_recorder = @import("ra8_session").history_recorder;

/// Reads every log segment's complete frames into one allocated stream.
pub fn readAll(allocator: std.mem.Allocator, store: history.storage.Store) ![]u8 {
    var gather: Gather = .{ .allocator = allocator, .store = store };
    errdefer gather.out.deinit(allocator);
    try store.vtable.list(store.context, .log, .{ .context = &gather, .visit = &Gather.visit });
    if (gather.failed) |err| return err;
    return gather.out.toOwnedSlice(allocator);
}

const Gather = struct {
    allocator: std.mem.Allocator,
    store: history.storage.Store,
    out: std.ArrayList(u8) = .empty,
    failed: ?anyerror = null,

    fn visit(context: *anyopaque, name: []const u8, size: u64) anyerror!void {
        _ = size;
        const self: *Gather = @ptrCast(@alignCast(context));
        if (self.failed != null) return;
        self.append(name) catch |err| {
            self.failed = err;
        };
    }

    fn append(self: *Gather, name: []const u8) !void {
        const file = try self.store.vtable.open(self.store.context, .log, name, .read);
        defer file.vtable.close(file.context);
        const length: usize = @intCast(try file.vtable.length(file.context));
        const start = self.out.items.len;
        try self.out.resize(self.allocator, start + length);
        var got: usize = 0;
        while (got < length) {
            const n = try file.vtable.read(file.context, got, self.out.items[start + got ..]);
            if (n == 0) break;
            got += n;
        }
        var frames: usize = 0;
        const hit = try session_log.scan(self.out.items[start .. start + got], &frames, count);
        self.out.shrinkRetainingCapacity(start + hit.complete_end);
    }
};

fn count(frames: *usize, boundary: session_log.Boundary) void {
    _ = boundary;
    frames.* += 1;
}

/// Cuts a torn tail off every log segment, the way a reopen does before the
/// recorder appends past it: a commit a crash cut short must not stay
/// between the whole frames and the ones written next. A whole frame that
/// fails its length or CRC refuses the reopen. Answers how many segments
/// were cut.
pub fn repair(allocator: std.mem.Allocator, store: history.storage.Store) !usize {
    var fix: Repair = .{ .allocator = allocator, .store = store };
    try store.vtable.list(store.context, .log, .{ .context = &fix, .visit = &Repair.visit });
    if (fix.failed) |err| return err;
    return fix.cut;
}

const Repair = struct {
    allocator: std.mem.Allocator,
    store: history.storage.Store,
    cut: usize = 0,
    failed: ?anyerror = null,

    fn visit(context: *anyopaque, name: []const u8, size: u64) anyerror!void {
        _ = size;
        const self: *Repair = @ptrCast(@alignCast(context));
        if (self.failed != null) return;
        self.segment(name) catch |err| {
            self.failed = err;
        };
    }

    fn segment(self: *Repair, name: []const u8) !void {
        const file = try self.store.vtable.open(self.store.context, .log, name, .update);
        defer file.vtable.close(file.context);
        const bytes = try self.allocator.alloc(u8, @intCast(try file.vtable.length(file.context)));
        defer self.allocator.free(bytes);
        var got: usize = 0;
        while (got < bytes.len) {
            const n = try file.vtable.read(file.context, got, bytes[got..]);
            if (n == 0) break;
            got += n;
        }
        var trim: Trim = .{ .file = file };
        const recovery = try session_recorder.recoverSegment(bytes[0..got], trim.storage());
        if (recovery.torn) self.cut += 1;
    }
};

/// The storage a recovery shortens a segment through: it only truncates.
const Trim = struct {
    file: history.storage.ByteFile,

    fn truncate(context: *anyopaque, len: u64) anyerror!void {
        const self: *Trim = @ptrCast(@alignCast(context));
        try self.file.vtable.truncate(self.file.context, len);
    }

    fn unsupported(context: *anyopaque) anyerror!void {
        _ = context;
        return error.Unsupported;
    }

    fn noAppend(context: *anyopaque, bytes: []const u8) anyerror!void {
        _ = context;
        _ = bytes;
        return error.Unsupported;
    }

    fn storage(self: *Trim) session_recorder.Storage {
        return .{ .context = self, .append = noAppend, .flush = unsupported, .truncate = truncate };
    }
};
