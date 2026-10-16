//! The native move peer's shared protocol driver: read the request, pin both
//! roots and the source entry, prove the intent, and rename only inside the
//! caller's window. Linux and Windows primitives live in linux.zig and
//! windows.zig; everything here is portable.
const std = @import("std");
const builtin = @import("builtin");
const wire = @import("wire.zig");
const verify = @import("verify.zig");
const Window = @import("window.zig").Window;
const metadata = @import("../metadata.zig");
const layout = @import("../layout.zig");
const intent = @import("intent.zig");

const platform = if (builtin.os.tag == .windows) @import("windows.zig") else @import("linux.zig");

/// Normal reply exits and watchdog exits. `unready` and `expired` mean no
/// rename started and `drained` that one returned. `unsettled` is the only
/// exit with a rename in flight: the call had not returned by commit plus
/// drain, and whether it renamed is whatever the directories show once the
/// process is gone.
pub const exits = struct {
    pub const success = 0;
    pub const rejected = 3;
    pub const expired = 4;
    pub const drained = 5;
    pub const unready = 6;
    pub const unsettled = 7;
};
var window: Window = .{};
/// The caller's ready bound once its request is read; until then the
/// longest any caller may configure.
var ready_ms: std.atomic.Value(u32) = .init(wire.Bounds.limit);
/// Written by `run` before it opens the window, read by the watchdog after.
var opened: std.Io.Timestamp = undefined;
var commit_ms: u32 = 0;
var drain_ms: u32 = 0;

pub fn peer(allocator: std.mem.Allocator, io: std.Io) !u8 {
    if (builtin.os.tag != .linux and builtin.os.tag != .windows) return error.OperationUnsupported;
    return run(allocator, io);
}

fn run(allocator: std.mem.Allocator, io: std.Io) !u8 {
    (try std.Thread.spawn(.{}, watch, .{io})).detach();
    const parsed = try wire.read(wire.Request, allocator, io, .stdin(), null);
    defer parsed.deinit();
    const request = parsed.value;
    try verify.frame(request);
    ready_ms.store(request.ready_ms, .seq_cst);
    var pins = try Pins.take(allocator, io, request);
    defer pins.close(io);
    var reply: wire.Reply = .{ .version = wire.version, .nonce = request.nonce, .operation = request.operation, .proof = try prove(allocator, io, pins, request), .phase = .bound, .pid = platform.selfPid(), .birth = try platform.birth(io), .source_inode = @intCast((try pins.source.stat(io)).inode), .source_root = @intCast((try pins.source_root.stat(io)).inode), .target_root = @intCast((try pins.target_root.stat(io)).inode) };
    commit_ms = request.commit_ms;
    drain_ms = request.drain_ms;
    opened = std.Io.Timestamp.now(io, .awake);
    if (!window.open()) park(io);
    try wire.write(allocator, io, .stdout(), reply);
    const committed = try wire.read(wire.Commit, allocator, io, .stdin(), null);
    defer committed.deinit();
    try verify.commit(request, committed.value);
    reply.phase = .done;
    // A COMMIT read after the window closed, or one that lost the race with
    // the watchdog, renames nothing. The clock is read here as well because
    // a peer suspended as a whole wakes with its watchdog not yet run.
    const late = opened.untilNow(io, .awake).toMilliseconds() >= request.commit_ms;
    reply.status = if (!late and window.claim()) status: {
        const renamed = platform.rename(allocator, pins.source, pins.source_root, request.from, pins.target_root, request.to);
        if (!window.settle()) park(io);
        break :status try renamed;
    } else .expired;
    try wire.write(allocator, io, .stdout(), reply);
    return if (reply.status == .success) exits.success else exits.rejected;
}

/// The intent the request names, read through this peer's own pins. The
/// request must name exactly it: its nonce and names, both roots as the
/// intent recorded them, and the digests of the bytes read here.
fn prove(allocator: std.mem.Allocator, io: std.Io, pins: Pins, request: wire.Request) !wire.Proof {
    const proof = try intent.boundProof(allocator, io, pins.source_root, pins.source, request.from);
    defer proof.deinit();
    const record = proof.record.value;
    const source = try platform.leafPath(allocator, record.from_path);
    defer allocator.free(source);
    const target = try platform.leafPath(allocator, record.to_path);
    defer allocator.free(target);
    try verify.bound(request, .{ .nonce = record.nonce, .from = record.from, .to = record.to, .source = source, .target = target, .proof = proof.digest });
    return proof.digest;
}

/// The watchdog starts with the process and owns every way the peer ends
/// itself. A peer not bound within the caller's ready bound ends here, and
/// so does one still waiting for COMMIT when its window closes, and its pins
/// and guards with it. A peer that renamed ends once the drain has passed,
/// reply written or not. A peer whose rename call has not returned by then
/// is ended as well: a thread stalled short of the call never makes it, and
/// a call the kernel can cancel is cancelled. A call the kernel will not
/// cancel keeps the process, its guards and so its proxy's flocks until it
/// returns; nothing in user mode ends that sooner.
fn watch(io: std.Io) void {
    const born = std.Io.Timestamp.now(io, .awake);
    while (true) : (io.sleep(.fromMilliseconds(tick_ms), .awake) catch {}) switch (window.state.load(.seq_cst)) {
        .starting => if (born.untilNow(io, .awake).toMilliseconds() >= ready_ms.load(.seq_cst) and window.unready()) end(exits.unready),
        .waiting => if (age(io) >= commit_ms and window.expire()) end(exits.expired),
        .committing => if (age(io) >= @as(u64, commit_ms) + drain_ms and window.abandon()) end(exits.unsettled),
        .settled => if (age(io) >= @as(u64, commit_ms) + drain_ms) end(exits.drained),
        .expired, .abandoned => {},
    };
}
const tick_ms = 10;

fn age(io: std.Io) i64 {
    return opened.untilNow(io, .awake).toMilliseconds();
}

/// End the whole process from the watchdog without running anything that
/// could wait on a stalled thread.
fn end(code: u8) noreturn {
    platform.terminate(code);
}

/// The watchdog won this stage and is ending the process.
fn park(io: std.Io) noreturn {
    while (true) io.sleep(.fromMilliseconds(tick_ms), .awake) catch {};
}

/// Both roots, the source entry and the root marker guards, held for the
/// whole exchange.
const Pins = struct {
    source_root: std.Io.Dir,
    target_root: std.Io.Dir,
    source: std.Io.Dir,
    source_guard: std.Io.File,
    target_guard: ?std.Io.File,

    fn take(allocator: std.mem.Allocator, io: std.Io, request: wire.Request) !Pins {
        var source_root = try platform.pinRoot(allocator, io, request.source);
        errdefer source_root.close(io);
        var target_root = try platform.pinRoot(allocator, io, request.target);
        errdefer target_root.close(io);
        var source = try platform.pin(allocator, io, source_root, request.from, true);
        errdefer source.close(io);
        const source_guard = try guard(io, source_root);
        errdefer source_guard.close(io);
        const same_root = (try source_root.stat(io)).inode == (try target_root.stat(io)).inode and std.mem.eql(u8, request.source.path, request.target.path);
        const target_guard = if (same_root) null else try guard(io, target_root);
        return .{ .source_root = source_root, .target_root = target_root, .source = source, .source_guard = source_guard, .target_guard = target_guard };
    }

    fn close(self: *Pins, io: std.Io) void {
        if (self.target_guard) |file| file.close(io);
        self.source_guard.close(io);
        self.source.close(io);
        self.target_root.close(io);
        self.source_root.close(io);
    }
};

/// Root markers contain bytes, so a surviving peer blocks all Base marker
/// checks even if its Linux proxy loses the inherited flock descriptors.
fn guard(io: std.Io, root: std.Io.Dir) !std.Io.File {
    const file = try metadata.open(io, root, layout.root.marker, .read_write);
    errdefer file.close(io);
    if (!try file.tryLock(io, .exclusive)) return error.Locked;
    return file;
}
