//! A native peer borrows the original Linux gates and leases through WSL.
const std = @import("std");
const builtin = @import("builtin");
const wire = @import("wire.zig");
const verify = @import("verify.zig");
const provider = @import("provider.zig");
const intent = @import("intent.zig");
const name = @import("../name.zig");
const Context = @import("context.zig").Context;
const Proxy = @import("proxy.zig").Proxy;
const Admission = @import("deadline.zig").Admission;
const deadline = @import("deadline.zig");

pub fn move(context: Context, from: []const u8, to: []const u8, purpose: []const u8) !void {
    if (builtin.os.tag != .linux) return error.OperationUnsupported;
    const base = context.source;
    const peer = base.native_provider orelse return error.NativePeerUnavailable;
    const admission = try admit(base.io, peer);
    try context.validate(from);
    if (intent.pending(base.io, base.dir, name.classify(from).id)) return error.Moving;
    var child = try prepare(context, peer, admission);
    defer child.close();
    const parsed = try intent.start(base.allocator, context, from, to, purpose);
    defer parsed.deinit();
    try exchange(context, peer, parsed.value, &child, admission);
}

/// The one admission of an exchange starts here, before any helper exists,
/// and every later phase runs inside it.
fn admit(io: std.Io, peer: provider.Provider) !Admission {
    try peer.bounds.check();
    return .begin(io, peer.bounds.total());
}

/// Validate the provider and both writable pipe bounds before any intent
/// becomes durable. Recovery uses the same checks before another exchange.
fn prepare(context: Context, peer: provider.Provider, admission: Admission) !Proxy {
    const base = context.source;
    try provider.check(base.io, peer);
    const source_path = try wire.windowsPath(base.allocator, base.path);
    defer base.allocator.free(source_path);
    const target_path = try wire.windowsPath(base.allocator, context.target.path);
    defer base.allocator.free(target_path);
    const source_root = try @import("file.zig").here(base.dir);
    const target_root = try @import("file.zig").here(context.target.dir);
    if (source_root.device_major != target_root.device_major or source_root.device_minor != target_root.device_minor) return error.CrossDevice;
    var child = try Proxy.spawn(context, peer.executable, peer.bounds.reap, admission);
    errdefer child.close();
    try child.fits();
    return child;
}

pub fn settle(context: Context, peer: ?provider.Provider, record: intent.Record) !void {
    const io = context.source.io;
    // Recovery is an admission of its own, so every verdict published here
    // obeys the same settle bound a first exchange obeys.
    const bounds = if (peer) |p| p.bounds else wire.Bounds{};
    const admission = if (peer) |p| try admit(io, p) else Admission.begin(io, bounds.total());
    const verdict = admission.phase(io, bounds.settle);
    try intent.scope(context, record, record.from, record.to);
    if (try intent.arrived(context, record)) {
        return finish(context, record, verdict);
    }
    if (!record.committed) return intent.cancel(context, record, verdict);
    try context.validate(record.from);
    const configured = peer orelse return error.NativeMoveUnknown;
    var child = try prepare(context, configured, admission);
    defer child.close();
    try exchange(context, configured, record, &child, admission);
}

fn complete(context: Context, record: intent.Record, status: wire.Status, verdict: deadline.Deadline) !void {
    switch (status) {
        .success => {
            if (!try intent.arrived(context, record)) return error.IdentityConflict;
            try finish(context, record, verdict);
        },
        .collision => {
            try intent.cancel(context, record, verdict);
            return error.PathAlreadyExists;
        },
        .cross_device => {
            try intent.cancel(context, record, verdict);
            return error.CrossDevice;
        },
        .refused => {
            try intent.cancel(context, record, verdict);
            return error.NativeMoveRefused;
        },
        // The peer's window closed before COMMIT reached it; nothing moved.
        .expired => {
            try intent.cancel(context, record, verdict);
            return error.NativeMoveExpired;
        },
    }
}

fn finish(context: Context, record: intent.Record, verdict: deadline.Deadline) !void {
    try context.authorized(record.from);
    try context.source.checkMarked();
    try context.target.checkMarked();
    try Context.owned(context.target, record.to);
    try verdict.live(context.source.io);
    try @import("file.zig").syncDir(context.target.dir);
    try @import("file.zig").syncDir(context.source.dir);
    try intent.cleanup(context, record, true, verdict);
}

fn exchange(context: Context, peer: provider.Provider, record: intent.Record, child: *Proxy, admission: Admission) !void {
    if (builtin.os.tag != .linux) return error.OperationUnsupported;
    const base = context.source;
    const allocator = base.allocator;
    const io = base.io;
    var flagged = record.committed;
    errdefer {
        child.close();
        // Nothing was committed, so no COMMIT can arrive and nothing has
        // moved: the intent is cancelled whatever became of the child.
        if (!flagged and admission.open(io)) intent.cancel(context, record, admission.phase(io, peer.bounds.settle)) catch {};
    }
    try intent.scope(context, record, record.from, record.to);
    try context.validate(record.from);
    const sent: verify.Sent = .{ .nonce = record.nonce, .operation = name.newId(io), .proof = try prove(context, record) };
    try send(context, peer, record, sent, child);
    const ready = wire.read(wire.Reply, allocator, io, child.child.stdout.?, admission.phase(io, peer.bounds.ready)) catch |err| return if (err == error.DeadlineExceeded) error.NativePeerTimeout else err;
    defer ready.deinit();
    // The peer opened its window before it wrote this reply, so this bound
    // ends no earlier than the peer's own unless the admission ends first,
    // and then the caller only gives up sooner.
    const drained = admission.phase(io, @as(u64, peer.bounds.commit) + peer.bounds.drain);
    try verify.reply(sent, ready.value, .bound);
    if (peer.observer) |observer| try observer.report(observer.context, .{ .proxy_pid = child.child.id.?, .reply = ready.value });
    try context.recheck(record.from, record.source, record.source_root, record.target_root);
    // COMMIT goes out only while the admission still covers the commit and
    // drain phases both: a COMMIT written later could outlive the reply
    // that settles it and strand the intent as unknown.
    if (drained.left(io) == null) return error.NativePeerTimeout;
    try intent.commit(context, record);
    flagged = true;
    child.commit(allocator, .{ .version = wire.version, .nonce = sent.nonce, .operation = sent.operation, .proof = sent.proof, .commit = true }) catch |err| return publish(context, record, admission, admission.phase(io, peer.bounds.settle), try lost(context, record, err));
    const done = wire.read(wire.Reply, allocator, io, child.child.stdout.?, drained) catch |err| {
        child.close();
        return publish(context, record, admission, admission.phase(io, peer.bounds.settle), try lost(context, record, err));
    };
    defer done.deinit();
    try verify.reply(sent, done.value, .done);
    try verify.pair(ready.value, done.value);
    if (peer.observer) |observer| try observer.report(observer.context, .{ .proxy_pid = child.child.id.?, .reply = done.value });
    const term = child.reap();
    // The settle phase owns every verdict published after the reap.
    const verdict = admission.phase(io, peer.bounds.settle);
    if (!admission.open(io)) return error.NativeMoveUnknown;
    return outcome(context, record, done.value.status, term, verdict);
}

/// The caller's own reading of the intent through the directories it holds
/// must still be the record it was given; its digests bind every frame.
fn prove(context: Context, record: intent.Record) !wire.Proof {
    const base = context.source;
    var source_dir = try base.dir.openDir(base.io, record.from, .{ .follow_symlinks = false });
    defer source_dir.close(base.io);
    const proof = try intent.boundProof(base.allocator, base.io, base.dir, source_dir, record.from);
    defer proof.deinit();
    const current = proof.record.value;
    if (!std.mem.eql(u8, &current.nonce, &record.nonce) or !current.source.same(record.source) or !current.source_root.same(record.source_root) or !current.target_root.same(record.target_root) or !current.anchor.same(record.anchor) or !current.marker.same(record.marker)) return error.IdentityConflict;
    if (!std.mem.eql(u8, current.to, record.to) or !std.mem.eql(u8, current.from_path, record.from_path) or !std.mem.eql(u8, current.to_path, record.to_path)) return error.IdentityConflict;
    const file = @import("file.zig");
    var anchor_buffer: name.Buffer = undefined;
    if (!record.anchor.same(try file.state(base.dir, try intent.leaf(&anchor_buffer, name.classify(record.from).id))) or !record.marker.same(try file.state(source_dir, intent.note))) return error.IdentityConflict;
    return proof.digest;
}

fn send(context: Context, peer: provider.Provider, record: intent.Record, sent: verify.Sent, child: *Proxy) !void {
    const base = context.source;
    const allocator = base.allocator;
    const io = base.io;
    // The running child must be the verified peer, not merely a file that
    // was the verified peer when it was checked on disk.
    try child.verifyExecutable(peer.executable, peer.sha256);
    if (!std.mem.eql(u8, &peer.sha256, &try provider.digest(io, peer.executable))) return error.PeerDigestMismatch;
    const source = try wire.windowsPath(allocator, base.path);
    defer allocator.free(source);
    const target = try wire.windowsPath(allocator, context.target.path);
    defer allocator.free(target);
    const request: wire.Request = .{ .version = wire.version, .nonce = sent.nonce, .operation = sent.operation, .proof = sent.proof, .source = .{ .path = source, .marker = try Context.marker(base) }, .target = .{ .path = target, .marker = try Context.marker(context.target) }, .from = record.from, .to = record.to, .ready_ms = peer.bounds.ready, .commit_ms = peer.bounds.commit, .drain_ms = peer.bounds.drain };
    if (peer.observer) |observer| try observer.report(observer.context, .{ .proxy_pid = 0, .reply = .{ .version = wire.version, .nonce = sent.nonce, .operation = sent.operation, .proof = sent.proof, .phase = .starting, .pid = 0, .birth = 0, .source_inode = 0, .source_root = 0, .target_root = 0 } });
    try wire.write(allocator, io, child.child.stdin.?, request);
}

/// A reply is not a cancellation proof without its matching native exit.
/// Success may outlive reap: the verified arrival, checked by complete,
/// settles that result even when the proxy is still draining. A watchdog
/// drain exit is also allowed only for a success reply and verified arrival.
pub fn outcome(context: Context, record: intent.Record, status: wire.Status, term: ?std.process.Child.Term, verdict: deadline.Deadline) !void {
    try context.source.checkMarked();
    try context.target.checkMarked();
    const exits = @import("windows.zig").exits;
    if (term) |ended| {
        const code = switch (ended) {
            .exited => |code| code,
            else => return error.NativePeerFailed,
        };
        if (status == .success) {
            if (code != exits.success and code != exits.drained) return error.NativePeerFailed;
        } else if (code != exits.rejected) return error.NativePeerFailed;
    } else if (status != .success) return error.NativeMoveUnknown;
    if (status == .success and !try intent.arrived(context, record)) return error.NativeMoveUnknown;
    try complete(context, record, status, verdict);
}

/// No verdict, arrival or cancellation, is published once the admission
/// has ended. The intent stays for recovery, which is an admission of its
/// own.
pub fn publish(context: Context, record: intent.Record, admission: Admission, verdict: deadline.Deadline, status: wire.Status) !void {
    if (!admission.open(context.source.io)) return error.NativeMoveUnknown;
    return complete(context, record, status, verdict);
}

/// COMMIT was written and no done reply came back: the rename may have
/// happened, or may still. Only an arrival seen now settles it. Anything
/// else, a root the surviving peer still guards included, is the same
/// unknown outcome and leaves the intent in place for recovery.
fn lost(context: Context, record: intent.Record, err: anyerror) !wire.Status {
    const unknown = if (err == error.DeadlineExceeded) error.NativeMoveUnknown else err;
    context.source.checkMarked() catch return unknown;
    context.target.checkMarked() catch return unknown;
    if (intent.arrived(context, record) catch return unknown) return .success;
    return unknown;
}
