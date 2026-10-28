//! The prefetch pool a served session with an on-disk history owns: the
//! session library's `Prefetch` state machine, the lock that serialises
//! it, and the worker threads that run its loads.
//!
//! The state machine holds no thread and no lock; this file supplies both.
//! Workers read checkpoint objects from the history's object space, which
//! is write-once, and hand the bytes back under the lock. They never touch
//! the live session, so prefetch never executes concurrently with Session
//! execution. The session reaches the pool through `attachPrefetch`; every
//! call it makes goes through `request` and `cancel` here, under the lock.
//!
//! How many workers run follows the RAM budget (`Prefetch.Config.forBudget`):
//! 1 GiB allows several, 512 MiB one, 256 MiB none.
const std = @import("std");
const history = @import("ra8_host").history;
const session_api = @import("ra8_session").api;
const prefetch = @import("ra8_session").history_prefetch;
pub const ObjectId = @import("ra8_session").history_object_id.ObjectId;

/// How the loads ended since the pool opened.
pub const Stats = struct {
    kept: u64 = 0,
    stale: u64 = 0,
    over_budget: u64 = 0,
    failed: u64 = 0,
};

pub const Pool = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    state: prefetch.Prefetch,
    /// Where workers read from. Replaceable before the first request.
    store_source: StoreSource,
    source: prefetch.ObjectSource,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    closing: bool = false,
    threads: []std.Thread = &.{},
    stats: Stats = .{},

    /// Opens a pool for `ram_budget` bytes over the objects `store` holds
    /// and starts the workers the budget allows.
    pub fn open(gpa: std.mem.Allocator, io: std.Io, ram_budget: u64, store: history.storage.Store) !*Pool {
        const self = try gpa.create(Pool);
        errdefer gpa.destroy(self);
        const config = prefetch.Config.forBudget(ram_budget, prefetch.default_share);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .state = prefetch.Prefetch.init(gpa, config),
            .store_source = .{ .store = store },
            .source = undefined,
        };
        self.source = self.store_source.source();
        errdefer self.state.deinit();
        self.threads = try gpa.alloc(std.Thread, config.workers);
        errdefer gpa.free(self.threads);
        var started: usize = 0;
        errdefer self.stopThreads(started);
        while (started < config.workers) : (started += 1) {
            self.threads[started] = try std.Thread.spawn(.{}, work, .{self});
        }
        return self;
    }

    /// Stops the workers, joins them and frees what they held. Call before
    /// the history the source reads from closes.
    pub fn close(self: *Pool) void {
        self.stopThreads(self.threads.len);
        self.gpa.free(self.threads);
        self.state.deinit();
        self.gpa.destroy(self);
    }

    fn stopThreads(self: *Pool, count: usize) void {
        self.mutex.lockUncancelable(self.io);
        self.closing = true;
        self.cond.broadcast(self.io);
        self.mutex.unlock(self.io);
        for (self.threads[0..count]) |thread| thread.join();
    }

    /// Workers running; zero when the budget allows none.
    pub fn workers(self: *const Pool) usize {
        return self.threads.len;
    }

    /// Queues one checkpoint's snapshot through the session and wakes a
    /// worker. A disabled or full pool refuses, which a caller may ignore:
    /// prefetch only ever saves time.
    pub fn request(self: *Pool, session: *session_api.Session, req: prefetch.Request) prefetch.Error!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try session.prefetch(req);
        self.cond.signal(self.io);
    }

    /// A transport command ran: bumps the epoch so queued requests drop and
    /// loads still running come back stale.
    pub fn cancel(self: *Pool, session: *session_api.Session) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        session.prefetchCancel();
    }

    /// The loaded snapshot of `object`, if a worker finished it in the
    /// current epoch; the caller owns the bytes (`gpa`).
    pub fn take(self: *Pool, object: ObjectId) ?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.state.takeObject(object);
    }

    /// How the loads ended so far, read under the lock.
    pub fn counts(self: *Pool) Stats {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.stats;
    }

    fn work(self: *Pool) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (!self.closing) {
            const claimed = self.state.claim() catch null;
            const job = claimed orelse {
                self.cond.waitUncancelable(self.io, &self.mutex);
                continue;
            };
            self.mutex.unlock(self.io);
            const loaded = prefetch.load(self.gpa, self.source, job);
            self.mutex.lockUncancelable(self.io);
            self.settle(job, loaded);
        }
    }

    fn settle(self: *Pool, job: prefetch.Job, loaded: prefetch.Error![]u8) void {
        const bytes = loaded catch {
            self.state.fail(job);
            self.stats.failed += 1;
            return;
        };
        const outcome = self.state.finish(job, bytes) catch {
            self.stats.failed += 1;
            return;
        };
        switch (outcome) {
            .kept => self.stats.kept += 1,
            .stale => self.stats.stale += 1,
            .over_budget => self.stats.over_budget += 1,
        }
    }
};

/// The history's checkpoint objects as a prefetch source: each read opens
/// the object's file afresh, so workers share no handle.
pub const StoreSource = struct {
    store: history.storage.Store,

    pub fn source(self: *StoreSource) prefetch.ObjectSource {
        return .{ .context = self, .read = &read, .hash = &digest };
    }

    fn read(context: *anyopaque, allocator: std.mem.Allocator, object: ObjectId) prefetch.Error![]u8 {
        const self: *StoreSource = @ptrCast(@alignCast(context));
        const name = nameOf(object);
        const file = self.store.vtable.open(self.store.context, .objects, &name, .read) catch return prefetch.Error.NotFound;
        defer file.vtable.close(file.context);
        const len = file.vtable.length(file.context) catch return prefetch.Error.NotFound;
        const buf = allocator.alloc(u8, @intCast(len)) catch return prefetch.Error.OutOfMemory;
        errdefer allocator.free(buf);
        var total: usize = 0;
        while (total < buf.len) {
            const n = file.vtable.read(file.context, total, buf[total..]) catch return prefetch.Error.NotFound;
            if (n == 0) break;
            total += n;
        }
        if (total != buf.len) return prefetch.Error.NotFound;
        return buf;
    }
};

/// A checkpoint object's name in the object space: its 128-bit digest as
/// 32 hex characters.
pub fn nameOf(object: ObjectId) [ObjectId.hex_len]u8 {
    var name: [ObjectId.hex_len]u8 = undefined;
    object.formatHex(&name);
    return name;
}

/// The digest the recorder files a checkpoint object under: the first
/// 128 bits of the bytes' SHA-256.
pub fn digest(bytes: []const u8) ObjectId {
    var full: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &full, .{});
    return .{ .bytes = full[0..ObjectId.len].* };
}
