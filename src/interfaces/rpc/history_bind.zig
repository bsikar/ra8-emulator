//! The application-side bridge from a host history session to the
//! harness's open options (RA8EMU-1196): the log storage and the object
//! space the persistent recorder writes through. The session library
//! defines the callback shapes and never opens a host file; the
//! applications own the history root and bridge it here, next to the
//! served sessions that use it. The bind holds the session's lease for
//! the run and deletes the ephemeral session on close, so no history
//! byte lands before the lifecycle is wired.
const std = @import("std");
const history = @import("ra8_host").history;
const session_recorder = @import("ra8_session").history_recorder;
const session_refs = @import("ra8_session").history_refs;

/// The run's first log segment. Segments number upward when the store
/// grows one; a bind opens segment zero.
const log_leaf = "events-0";

pub const Bind = struct {
    gpa: std.mem.Allocator,
    base: history.base.Base,
    session: history.session.Session,
    log: history.storage.ByteFile,
    sink: *LogSink,
    /// The shapes the harness's open options take. Both point into this
    /// bind, which stays put until close.
    storage: session_recorder.Storage,
    objects: session_recorder.Objects,
    /// The disk budget the recorder checks before every commit and
    /// checkpoint: this history's share of the volume and a fresh
    /// free-space read per check.
    disk: ?session_recorder.Budget = null,
    watch: ?*VolumeWatch = null,
    /// The checkpoints partition's bytes, what the cadence projection
    /// keeps the checkpoint objects within.
    checkpoint_cap: u64 = 0,

    /// Open a history root at `path`, made and marked when it is new,
    /// and make the run's session in it with the lease held.
    pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !*Bind {
        const bind = try allocator.create(Bind);
        errdefer allocator.destroy(bind);
        bind.* = .{ .gpa = allocator, .base = undefined, .session = undefined, .log = undefined, .sink = undefined, .storage = undefined, .objects = undefined };
        bind.base = try history.base.Base.openConfigured(allocator, io, path, .cache, .{});
        errdefer bind.base.close();
        bind.session = try history.session.Session.create(&bind.base, .{});
        errdefer _ = bind.session.close(null, .move) catch {};
        const store = history.storage.Store.from(&bind.session);
        bind.log = try store.vtable.open(store.context, .log, log_leaf, .create);
        errdefer bind.log.vtable.close(bind.log.context);
        bind.sink = try allocator.create(LogSink);
        errdefer allocator.destroy(bind.sink);
        bind.sink.* = .{ .byte = bind.log };
        bind.storage = .{ .context = bind.sink, .append = &appendLog, .flush = &flushLog, .truncate = &truncateLog };
        bind.objects = .{ .context = bind, .put = &putObject, .sync = &syncObjects };
        // The budget: one read at open sizes the share this history
        // takes, and every check reads the volume fresh.
        const volume = try history.resources.volume(allocator, io, bind.base.dir);
        const shares = history.budget.disk(volume.total, 1);
        const watch = try allocator.create(VolumeWatch);
        errdefer allocator.destroy(watch);
        watch.* = .{ .gpa = allocator, .io = io, .dir = bind.base.dir };
        bind.watch = watch;
        bind.disk = .{ .context = watch, .free = &freeVolume, .cap = shares.session, .floor = shares.free_floor };
        bind.checkpoint_cap = shares.checkpoints;
        return bind;
    }

    /// End the run: the log closes first, then the session (an ephemeral
    /// one deletes, and every file inside it is closed by then), then
    /// the root.
    pub fn close(self: *Bind) !history.session.Outcome {
        const gpa = self.gpa;
        self.log.vtable.close(self.log.context);
        self.disk = null;
        if (self.watch) |watch| gpa.destroy(watch);
        self.watch = null;
        if (self.session.close(null, .move)) |outcome| {
            self.base.close();
            gpa.destroy(self.sink);
            gpa.destroy(self);
            return outcome;
        } else |err| {
            self.base.close();
            gpa.destroy(self.sink);
            gpa.destroy(self);
            return err;
        }
    }

    /// The log segment's length, where a reader's tail sits.
    pub fn logLength(self: *Bind) !u64 {
        return self.log.vtable.length(self.log.context);
    }
};

const LogSink = struct { byte: history.storage.ByteFile };

/// Reads the volume fresh for every budget check; the history root's
/// directory is the handle the read goes through.
const VolumeWatch = struct { gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir };

fn freeVolume(context: *anyopaque) anyerror!u64 {
    const watch: *VolumeWatch = @ptrCast(@alignCast(context));
    const volume = try history.resources.volume(watch.gpa, watch.io, watch.dir);
    return volume.available;
}

fn sinkOf(context: *anyopaque) *LogSink {
    return @ptrCast(@alignCast(context));
}

fn appendLog(context: *anyopaque, bytes: []const u8) anyerror!void {
    const byte = sinkOf(context).byte;
    const end = try byte.vtable.length(byte.context);
    try byte.vtable.write(byte.context, end, bytes);
}

fn flushLog(context: *anyopaque) anyerror!void {
    const byte = sinkOf(context).byte;
    try byte.vtable.sync(byte.context);
}

fn truncateLog(context: *anyopaque, len: u64) anyerror!void {
    const byte = sinkOf(context).byte;
    try byte.vtable.truncate(byte.context, len);
}

fn bindOf(context: *anyopaque) *Bind {
    return @ptrCast(@alignCast(context));
}

/// Store the bytes under the recorder's name. Names are content
/// addresses, so a repeat put of the same bytes is already durable.
fn putObject(context: *anyopaque, name: []const u8, bytes: []const u8) anyerror!void {
    const bind = bindOf(context);
    const store = history.storage.Store.from(&bind.session);
    var file = store.vtable.open(store.context, .objects, name, .create) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        else => return err,
    };
    defer file.vtable.close(file.context);
    try file.vtable.write(file.context, 0, bytes);
    try file.vtable.sync(file.context);
}

/// Every object put synced its own file, so a batch needs nothing.
fn syncObjects(context: *anyopaque) anyerror!void {
    _ = context;
}

/// The host prune's referrer: names every object the committed log
/// names. Reads the store's log segments and walks each one's committed
/// frames through the session library's scan; a segment the walk cannot
/// finish is a hard error, so the sweep never deletes past it.
pub const prune_referrer: history.prune.Referrer = .{ .collect = &collectReferenced };

const PruneGather = struct {
    allocator: std.mem.Allocator,
    names: *std.StringHashMap(void),
    failed: ?anyerror = null,

    fn add(self: *PruneGather, name: session_refs.Name) void {
        if (self.failed != null) return;
        const key = self.allocator.dupe(u8, &name) catch {
            self.failed = error.OutOfMemory;
            return;
        };
        const hit = self.names.getOrPut(key) catch {
            self.allocator.free(key);
            self.failed = error.OutOfMemory;
            return;
        };
        if (hit.found_existing) self.allocator.free(key);
    }
};

const PruneSegments = struct {
    store: history.storage.Store,
    gather: *PruneGather,

    fn visit(context: *anyopaque, name: []const u8, size: u64) anyerror!void {
        _ = size;
        const self: *PruneSegments = @ptrCast(@alignCast(context));
        const file = try self.store.vtable.open(self.store.context, .log, name, .read);
        defer file.vtable.close(file.context);
        const length: usize = @intCast(try file.vtable.length(file.context));
        const bytes = try self.gather.allocator.alloc(u8, length);
        defer self.gather.allocator.free(bytes);
        var got: usize = 0;
        while (got < bytes.len) {
            const read = try file.vtable.read(file.context, got, bytes[got..]);
            if (read == 0) break;
            got += read;
        }
        session_refs.scanCheckpointObjects(bytes[0..got], self.gather, PruneGather.add) catch |err| {
            self.gather.failed = err;
        };
    }
};

fn collectReferenced(store: history.storage.Store, allocator: std.mem.Allocator, names: *std.StringHashMap(void)) anyerror!void {
    var gather = PruneGather{ .allocator = allocator, .names = names };
    var segments = PruneSegments{ .store = store, .gather = &gather };
    try store.vtable.list(store.context, .log, .{ .context = &segments, .visit = &PruneSegments.visit });
    if (gather.failed) |err| return err;
}
