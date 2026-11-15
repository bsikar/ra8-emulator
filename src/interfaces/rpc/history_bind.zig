//! The application-side bridge from a host history session to the
//! harness's open options (RA8EMU-1196): the log storage and the object
//! space the persistent recorder writes through. The session library
//! defines the callback shapes and never opens a host file; the
//! applications own the history root and bridge it here, next to the
//! served sessions that use it. The bind holds the session's lease for
//! the run and deletes the ephemeral session on close, so no history
//! byte lands before the lifecycle is wired.
const history_references = @import("history_references.zig");
const history_startup = @import("history_startup.zig");
const history_validity = @import("history_validity.zig");
const served_initial = @import("served_initial.zig");
const served_media = @import("served_media.zig");

const std = @import("std");

const branches_recover = @import("ra8_session").history_branches_recover;
const history = @import("ra8_host").history;
const history_live = @import("history_live.zig");
const history_pending = @import("history_pending.zig");
const history_root = @import("ra8_session").history_root;
const history_segments = @import("history_segments.zig");
const pack_store = @import("pack_store.zig");
const session_branch = @import("ra8_session").history_branch;
const session_branches_codec = @import("ra8_session").history_branches_codec;
const session_fork = @import("ra8_session").history_fork_router;
const session_fork_types = @import("ra8_session").fork;
const session_recorder = @import("ra8_session").history_recorder;

/// Formats the segment leaf name for a given branch and segment index.
pub fn segmentName(buf: []u8, branch: u32, seg: u32) ![]const u8 {
    if (branch == 0 and seg == 0) return "events-0";
    return std.fmt.bufPrint(buf, "events-{d}-{d}", .{ branch, seg });
}

/// The first log segment; later segments number upward.
const log_leaf = "events-0";
pub const Bind = struct {
    gpa: std.mem.Allocator,
    pending: history_pending.Pending,
    base: history.base.Base,
    session: history.session.Session,
    log: history.storage.ByteFile,
    sink: *LogSink,
    /// The shapes the harness's open options take. Both point into this
    /// bind, which stays put until close.
    storage: session_recorder.Storage,
    objects: session_recorder.Objects,
    /// The pack store the checkpoint engine's page and blob objects go to.
    packs: *pack_store.PackStore = undefined,
    /// The disk budget the recorder checks before every commit and
    /// checkpoint: this history's share of the volume and a fresh
    /// free-space read per check.
    disk: ?session_recorder.Budget = null,
    watch: ?*VolumeWatch = null,
    /// The checkpoints partition's bytes, what the cadence projection
    /// keeps the checkpoint objects within.
    checkpoint_cap: u64 = 0,
    io: std.Io = undefined,
    graph: session_branch.BranchGraph = undefined,
    router: session_fork.ForkRouter = undefined,
    graph_sink: session_fork_types.GraphSink = undefined,
    root: ?history_root.Root = null,
    /// Owns every slice borrowed by a decoded root until the bind closes.
    root_bytes: ?[]u8 = null,
    media_bytes: ?[]u8 = null,
    /// Set when the session stopped recording into this history (a
    /// different image loaded): close leaves its branches.bin as it was,
    /// since the in-memory graph then describes the new program.
    detached: bool = false,
    /// Set when this bind took over a session an earlier run recorded.
    reopened: bool = false,

    /// Open a history root at `path`, made and marked when it is new,
    /// and make the run's session in it with the lease held.
    pub const Options = struct {
        /// An explicit session share cap in bytes, instead of the volume's
        /// computed share. The volume's free floor and the relief stay.
        cap: ?u64 = null,
        kept: bool = false,
        /// Take over this kept session instead of making a new one: its
        /// log, objects and caches are served again, and recording
        /// continues past the line's recorded end.
        reopen: ?history.name.Id = null,
        board_profile: ?[]const u8 = null,
        images: ?*served_initial.Images = null,
    };

    pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8, opts: Options) !*Bind {
        const bind = try allocate(allocator);
        errdefer allocator.destroy(bind);
        errdefer bind.pending.deinit();
        bind.base = if (opts.reopen != null)
            try history.base.Base.existingConfigured(allocator, io, path, .cache, .{ .recover = false })
        else
            try history_startup.openFresh(allocator, io, path);
        errdefer bind.base.close();
        bind.session = if (opts.reopen) |id|
            try history.session.Session.reopenUnsettled(&bind.base, id)
        else
            try history.session.Session.create(&bind.base, .{});
        errdefer if (opts.reopen != null) {
            bind.session.dir.close(io);
            bind.session.lock.close(io);
        } else {
            _ = bind.session.close(null, .move) catch {};
        };
        try initialize(bind, allocator, io, opts);
        return bind;
    }

    /// Borrow a validated import's lease until success, then take ownership without an unlock gap.
    pub fn adopt(allocator: std.mem.Allocator, base: *history.base.Base, incoming: *history.session.Session) !*Bind {
        const bind = try allocate(allocator);
        errdefer allocator.destroy(bind);
        errdefer bind.pending.deinit();
        bind.base = base.*;
        bind.session = incoming.*;
        bind.session.base = &bind.base;
        try initialize(bind, allocator, base.io, .{ .reopen = incoming.id });
        return bind;
    }

    fn allocate(allocator: std.mem.Allocator) !*Bind {
        const bind = try allocator.create(Bind);
        bind.* = .{
            .gpa = allocator,
            .pending = .init(allocator),
            .base = undefined,
            .session = undefined,
            .log = undefined,
            .sink = undefined,
            .storage = undefined,
            .objects = undefined,
        };
        return bind;
    }

    fn initialize(bind: *Bind, allocator: std.mem.Allocator, io: std.Io, opts: Options) !void {
        errdefer if (bind.media_bytes) |bytes| allocator.free(bytes);
        errdefer if (bind.root_bytes) |bytes| allocator.free(bytes);
        try bind.readRoot(opts);
        if (opts.reopen != null) try history.rename.settle(io, bind.session.dir);
        if (opts.kept) try bind.session.keep();
        const graph = try bind.recoverGraph(allocator, opts.reopen != null);
        bind.io = io;
        bind.graph = graph;
        errdefer bind.graph.deinit();
        bind.router = session_fork.ForkRouter.init(allocator, &bind.graph);
        errdefer bind.router.deinit();
        bind.graph_sink = .{ .context = bind, .writeFn = &writeBranchesBin };
        const store = history.storage.Store.from(&bind.session);
        bind.reopened = opts.reopen != null;
        bind.log = try store.vtable.open(store.context, .log, log_leaf, if (bind.reopened) .update else .create);
        errdefer bind.log.vtable.close(bind.log.context);
        bind.sink = try allocator.create(LogSink);
        errdefer allocator.destroy(bind.sink);
        bind.sink.* = .{ .bind = bind, .byte = bind.log, .prepared = .init(allocator) };
        errdefer bind.sink.prepared.deinit();
        bind.storage = .{
            .context = bind.sink,
            .append = &appendLog,
            .flush = &flushLog,
            .truncate = &truncateLog,
            .switchSegment = &switchSegmentLog,
        };
        bind.packs = try pack_store.PackStore.open(allocator, &bind.session);
        errdefer bind.packs.close();
        bind.objects = .{
            .context = bind,
            .put = &history_pending.putObject,
            .sync = &syncObjects,
            .putPacked = &history_pending.putPacked,
        };
        try bind.bindBudget(allocator, io, store, opts.cap);
    }

    /// End the run: the log closes first, then the session (an ephemeral
    /// one deletes, and every file inside it is closed by then), then
    /// the root.
    pub fn close(self: *Bind) !history.session.Outcome {
        const gpa = self.gpa;
        self.packs.close();
        self.pending.deinit();
        self.sink.prepared.deinit();
        self.log.vtable.close(self.log.context);
        self.disk = null;
        if (self.watch) |watch| gpa.destroy(watch);
        self.watch = null;
        // The graph's last state, recorded ends included, reaches
        // branches.bin; a write that fails is reported once the session
        // and the root are closed, not dropped.
        const saved: anyerror!void = if (self.detached) {} else self.saveGraph();
        self.router.deinit();
        self.graph.deinit();
        defer {
            self.base.close();
            if (self.root_bytes) |bytes| gpa.free(bytes);
            if (self.media_bytes) |bytes| gpa.free(bytes);
            gpa.destroy(self.sink);
            gpa.destroy(self);
        }
        const outcome = try self.session.close(null, .move);
        try saved;
        return outcome;
    }

    fn bindBudget(
        self: *Bind,
        allocator: std.mem.Allocator,
        io: std.Io,
        store: history.storage.Store,
        cap: ?u64,
    ) !void {
        // The budget: one read at open sizes the share this history
        // takes, and every check reads the volume fresh.
        const volume = try history.resources.volume(allocator, io, self.base.dir);
        const shares = if (cap) |capped|
            try history.budget.diskCapped(volume.total, 1, capped)
        else
            history.budget.disk(volume.total, 1);
        const watch = try allocator.create(VolumeWatch);
        errdefer allocator.destroy(watch);
        watch.* = .{ .gpa = allocator, .io = io, .dir = self.base.dir, .store = store, .pending = &self.pending };
        self.watch = watch;
        watch.packs = self.packs;
        self.disk = .{
            .context = watch,
            .free = &freeVolume,
            .cap = shares.session,
            .floor = shares.free_floor,
            .relief = &relieveVolume,
        };
        self.checkpoint_cap = shares.checkpoints;
    }

    fn recoverGraph(self: *Bind, allocator: std.mem.Allocator, reopen: bool) !session_branch.BranchGraph {
        const io = self.base.io;
        var candidates = try history.branches_file.readCandidates(io, self.session.dir, allocator);
        defer candidates.deinit(allocator);
        // A reopened log may end in a commit a crash cut short: it is cut
        // off before anything reads the log or the recorder appends to it.
        if (reopen) _ = try history_segments.repair(allocator, history.storage.Store.from(&self.session));
        // The log is the last source: a graph rebuilt from its Branch
        // records when neither file decodes, recorded ends raised from it.
        const log_bytes = try history_segments.readAll(allocator, history.storage.Store.from(&self.session));
        defer allocator.free(log_bytes);
        const rec = try branches_recover.recoverWithLog(allocator, candidates.current, candidates.temp, log_bytes);
        switch (rec.action) {
            .use_temp => history.branches_file.settle(io, self.session.dir) catch {},
            else => history.branches_file.cleanupTemp(io, self.session.dir),
        }
        return rec.graph;
    }

    fn readRoot(self: *Bind, opts: Options) !void {
        if (opts.reopen != null) try served_initial.checkRootRename(self.base.io, self.session.dir);
        self.root_bytes = try history.branches_file.readAlloc(
            self.base.io,
            self.session.dir,
            history.layout.files.root,
            self.gpa,
        );
        if (self.root_bytes) |bytes| self.root = history_root.decode(bytes) catch null;
        if (opts.reopen == null) return;
        const root = self.root orelse return error.NoRoot;
        try history_validity.check(root);
        if (opts.board_profile) |profile| {
            if (!std.mem.eql(u8, profile, root.board_profile)) return error.BoardProfileMismatch;
        }
        if (opts.images) |images| try images.check(root);
        if (root.media) |id| self.media_bytes = try served_media.read(
            self.gpa,
            history.storage.Store.from(&self.session),
            id,
        );
    }

    fn saveGraph(self: *Bind) anyerror!void {
        const encoded = try session_branches_codec.encodeAlloc(&self.graph, self.gpa);
        defer self.gpa.free(encoded);
        try history.branches_file.writeAtomic(self.io, self.session.dir, encoded);
    }

    /// The log segment's length, where a reader's tail sits.
    pub fn logLength(self: *Bind) !u64 {
        return self.log.vtable.length(self.log.context);
    }
};

const LogSink = struct {
    bind: *Bind,
    byte: history.storage.ByteFile,
    prepared: history_pending.Pending,
    unsafe_from: ?u64 = null,
};

/// Reads the volume fresh for every budget check; the history root's
/// directory is the handle the read goes through. The store rides along
/// for the relief the budget's refusal path runs.
const VolumeWatch = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    store: history.storage.Store,
    pending: *history_pending.Pending,
    packs: ?*pack_store.PackStore = null,
};

/// Pending object writes stay live until the log's durable flush acknowledges them.
fn relieveVolume(context: *anyopaque) anyerror!void {
    const watch: *VolumeWatch = @ptrCast(@alignCast(context));
    var referrer = prune_referrer;
    referrer.extra = .{ .context = watch.pending, .collect = &history_pending.Pending.collect };
    _ = try history.prune.relief(watch.store, watch.gpa, referrer);
    if (watch.packs) |packs| _ = try history_live.compactPacksWithReferrer(watch.store, watch.gpa, packs, referrer);
}

fn freeVolume(context: *anyopaque) anyerror!u64 {
    const watch: *VolumeWatch = @ptrCast(@alignCast(context));
    const volume = try history.resources.volume(watch.gpa, watch.io, watch.dir);
    return volume.available;
}

fn sinkOf(context: *anyopaque) *LogSink {
    return @ptrCast(@alignCast(context));
}

fn writeBranchesBin(context: *anyopaque, encoded: []const u8) anyerror!void {
    const b: *Bind = @ptrCast(@alignCast(context));
    try history.branches_file.writeAtomic(b.io, b.session.dir, encoded);
}

fn appendLog(context: *anyopaque, bytes: []const u8) anyerror!void {
    const sink = sinkOf(context);
    errdefer sink.prepared.clear();
    const end = try sink.byte.vtable.length(sink.byte.context);
    if (sink.unsafe_from == null) {
        if (!sink.prepared.prepare(history.storage.Store.from(&sink.bind.session), bytes)) sink.unsafe_from = end;
    }
    sink.byte.vtable.write(sink.byte.context, end, bytes) catch |err| {
        sink.unsafe_from = @min(sink.unsafe_from orelse end, end);
        return err;
    };
}

fn flushLog(context: *anyopaque) anyerror!void {
    const sink = sinkOf(context);
    try sink.byte.vtable.sync(sink.byte.context);
    sink.bind.pending.acknowledge(&sink.prepared);
    sink.prepared.clear();
}

fn truncateLog(context: *anyopaque, len: u64) anyerror!void {
    const sink = sinkOf(context);
    sink.prepared.clear();
    try sink.byte.vtable.truncate(sink.byte.context, len);
    if (sink.unsafe_from) |at| if (len <= at) {
        sink.unsafe_from = null;
    };
}

/// Moves appends to segment `seg` of `branch`: the current segment is
/// made durable first (a failure leaves appends where they were), then
/// the target opens for update when it exists and is made when it does
/// not. Answers the bytes the target already holds.
fn switchSegmentLog(context: *anyopaque, branch: u32, seg: u32) anyerror!u64 {
    const sink = sinkOf(context);
    sink.prepared.clear();
    const bind = sink.bind;
    var buf: [64]u8 = undefined;
    const leaf = try segmentName(&buf, branch, seg);
    const store = history.storage.Store.from(&bind.session);
    try sink.byte.vtable.sync(sink.byte.context);
    const new_byte = store.vtable.open(store.context, .log, leaf, .create) catch |err| switch (err) {
        error.PathAlreadyExists => try store.vtable.open(store.context, .log, leaf, .update),
        else => return err,
    };
    errdefer new_byte.vtable.close(new_byte.context);
    const length = try new_byte.vtable.length(new_byte.context);
    sink.byte.vtable.close(sink.byte.context);
    sink.byte = new_byte;
    bind.log = new_byte;
    // Certify old bytes once here, keeping normal flushes batch-local.
    sink.unsafe_from = if (history_pending.validSegment(bind.gpa, new_byte, length)) null else 0;
    return length;
}

fn bindOf(context: *anyopaque) *Bind {
    return @ptrCast(@alignCast(context));
}

/// Every loose object synced its own file; the pack store's waiting
/// objects reach disk here, pack before index.
fn syncObjects(context: *anyopaque) anyerror!void {
    try bindOf(context).packs.seal();
}

pub const prune_referrer = history_references.prune_referrer;
