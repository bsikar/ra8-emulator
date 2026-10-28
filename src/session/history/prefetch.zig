//! Prefetch policy and bookkeeping: which checkpoint snapshots may be
//! loaded ahead of a seek, how many at once, and which results still count.
//!
//! This file is the state machine only. It holds no thread and no lock:
//! the application that owns the worker threads serialises calls to it,
//! and runs `load` on a worker. A worker reads immutable objects through
//! `ObjectSource` and hands the bytes back with `finish`; it never touches
//! the live session, never runs the machine and never mutates what it
//! loaded, so prefetch cannot execute concurrently with Session execution.
//!
//! Budget (the session's RAM budget table): workers draw on the
//! checkpoints' share, 5/8 of the budget, in fixed shares of 128 MiB each.
//! A 1 GiB budget allows several workers, 512 MiB at most one, and 256 MiB
//! and the 128 MiB floor none.
//!
//! Epochs: every transport command bumps the epoch. A request still
//! queued is dropped by the bump, and a worker's result carries the epoch
//! it started in, so a result that comes back after a newer command is
//! discarded instead of kept.
const std = @import("std");
const ObjectId = @import("object_id.zig").ObjectId;

pub const mib: u64 = 1024 * 1024;
/// The memory one worker's snapshot may take.
pub const default_share: u64 = 128 * mib;

pub const Error = error{ Disabled, OverBudget, NotFound, BadHash, OutOfMemory };

pub const Config = struct {
    /// Workers allowed at once; zero disables prefetch.
    workers: u32,
    /// Bytes one worker reserves.
    share: u64,
    /// Bytes the in-flight, queued and ready snapshots may hold together.
    capacity: u64,

    /// The configuration a RAM budget allows.
    pub fn forBudget(ram_budget: u64, share: u64) Config {
        const capacity = ram_budget / 8 * 5;
        const fit: u64 = if (share == 0) 0 else capacity / share;
        const workers: u64 = if (ram_budget >= 1024 * mib)
            fit
        else if (ram_budget >= 512 * mib)
            @min(fit, 1)
        else
            0;
        return .{ .workers = @intCast(@min(workers, 64)), .share = share, .capacity = capacity };
    }
};

/// One checkpoint snapshot to load: the checkpoint and the object that
/// pins its state.
pub const Request = struct {
    id: u32,
    object: ObjectId,
};

/// A claimed request and the epoch it was claimed in.
pub const Job = struct {
    request: Request,
    epoch: u64,
};

/// What `finish` did with a result.
pub const Finished = enum { kept, stale, over_budget };

/// Read-only access to immutable objects. `hash` names the digest the
/// store files its objects under; a store that names them another way
/// than the content-addressed engine does supplies its own.
pub const ObjectSource = struct {
    context: *anyopaque,
    read: *const fn (context: *anyopaque, allocator: std.mem.Allocator, object: ObjectId) Error![]u8,
    hash: *const fn (bytes: []const u8) ObjectId = &ObjectId.compute,
};

/// A worker's body: reads the snapshot and refuses bytes that do not hash
/// to the object they were asked under. The caller owns the result.
pub fn load(allocator: std.mem.Allocator, source: ObjectSource, job: Job) Error![]u8 {
    const bytes = try source.read(source.context, allocator, job.request.object);
    errdefer allocator.free(bytes);
    if (!source.hash(bytes).eql(job.request.object)) return Error.BadHash;
    return bytes;
}

const Ready = struct { id: u32, object: ObjectId, bytes: []u8 };

pub const Prefetch = struct {
    allocator: std.mem.Allocator,
    config: Config,
    epoch: u64 = 0,
    queue: std.ArrayList(Request) = .empty,
    claimed: std.ArrayList(Job) = .empty,
    ready: std.ArrayList(Ready) = .empty,
    ready_bytes: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, config: Config) Prefetch {
        return .{ .allocator = allocator, .config = config };
    }

    pub fn deinit(self: *Prefetch) void {
        for (self.ready.items) |entry| self.allocator.free(entry.bytes);
        self.ready.deinit(self.allocator);
        self.queue.deinit(self.allocator);
        self.claimed.deinit(self.allocator);
        self.* = undefined;
    }

    /// Queues a snapshot. Asking again for one already queued, running or
    /// ready is a no-op.
    pub fn request(self: *Prefetch, req: Request) Error!void {
        if (self.config.workers == 0) return Error.Disabled;
        if (self.known(req.id)) return;
        if (self.committed() + self.config.share > self.config.capacity) return Error.OverBudget;
        try self.queue.append(self.allocator, req);
    }

    /// Hands the oldest queued request to a worker, if a worker slot and
    /// the share allow.
    pub fn claim(self: *Prefetch) Error!?Job {
        if (self.queue.items.len == 0 or self.claimed.items.len >= self.config.workers) return null;
        const job: Job = .{ .request = self.queue.items[0], .epoch = self.epoch };
        try self.claimed.append(self.allocator, job);
        _ = self.queue.orderedRemove(0);
        return job;
    }

    /// A worker's result. Takes ownership of `bytes`: kept for `take`, or
    /// freed when the epoch has moved on or the snapshot no longer fits.
    pub fn finish(self: *Prefetch, job: Job, bytes: []u8) Error!Finished {
        self.release(job);
        if (job.epoch != self.epoch) {
            self.allocator.free(bytes);
            return .stale;
        }
        const room = self.config.capacity -| (self.ready_bytes + self.reservedShares());
        if (bytes.len > room) {
            self.allocator.free(bytes);
            return .over_budget;
        }
        self.ready.append(self.allocator, .{ .id = job.request.id, .object = job.request.object, .bytes = bytes }) catch |err| {
            self.allocator.free(bytes);
            return err;
        };
        self.ready_bytes += bytes.len;
        return .kept;
    }

    /// A worker that could not load: frees its slot, keeps nothing.
    pub fn fail(self: *Prefetch, job: Job) void {
        self.release(job);
    }

    /// A transport command ran: drops what is queued and makes every
    /// running worker's result stale. Returns the new epoch.
    pub fn bump(self: *Prefetch) u64 {
        self.epoch += 1;
        self.queue.clearRetainingCapacity();
        return self.epoch;
    }

    /// Takes a loaded snapshot, transferring ownership to the caller.
    pub fn take(self: *Prefetch, id: u32) ?[]u8 {
        for (self.ready.items, 0..) |entry, i| {
            if (entry.id != id) continue;
            _ = self.ready.orderedRemove(i);
            self.ready_bytes -= entry.bytes.len;
            return entry.bytes;
        }
        return null;
    }

    /// Takes the loaded snapshot of `object`, whichever checkpoint asked
    /// for it, transferring ownership to the caller.
    pub fn takeObject(self: *Prefetch, object: ObjectId) ?[]u8 {
        for (self.ready.items) |entry| {
            if (entry.object.eql(object)) return self.take(entry.id);
        }
        return null;
    }

    pub fn running(self: *const Prefetch) usize {
        return self.claimed.items.len;
    }

    pub fn queued(self: *const Prefetch) usize {
        return self.queue.items.len;
    }

    fn release(self: *Prefetch, job: Job) void {
        for (self.claimed.items, 0..) |held, i| {
            if (held.request.id == job.request.id and held.epoch == job.epoch) {
                _ = self.claimed.orderedRemove(i);
                return;
            }
        }
    }

    fn reservedShares(self: *const Prefetch) u64 {
        return (self.queue.items.len + self.claimed.items.len) * self.config.share;
    }

    fn committed(self: *const Prefetch) u64 {
        return self.ready_bytes + self.reservedShares();
    }

    fn known(self: *const Prefetch, id: u32) bool {
        for (self.queue.items) |req| if (req.id == id) return true;
        for (self.claimed.items) |job| if (job.request.id == id) return true;
        for (self.ready.items) |entry| if (entry.id == id) return true;
        return false;
    }
};
