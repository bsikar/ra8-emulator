//! A native peer borrows the original Linux gates and leases through WSL.
const std = @import("std");
const builtin = @import("builtin");
const wire = @import("wire.zig");
const provider = @import("provider.zig");
const intent = @import("intent.zig");
const Context = @import("context.zig").Context;
const Proxy = @import("proxy.zig").Proxy;
const Deadline = @import("deadline.zig").Deadline;

pub fn move(context: Context, from: []const u8, to: []const u8, purpose: []const u8) !void {
    if (builtin.os.tag != .linux) return error.OperationUnsupported;
    const base = context.source;
    const peer = base.native_provider orelse return error.NativePeerUnavailable;
    try context.validate(from);
    if (intent.pending(base.io, base.dir, @import("../name.zig").classify(from).id)) return error.Moving;
    var child = try prepare(context, peer);
    defer child.close();
    const parsed = try intent.start(base.allocator, context, from, to, purpose);
    defer parsed.deinit();
    try exchange(context, peer, parsed.value, &child);
}

/// Validate the provider and both writable pipe bounds before any intent
/// becomes durable. Recovery uses the same checks before another exchange.
fn prepare(context: Context, peer: provider.Provider) !Proxy {
    const base = context.source;
    try peer.bounds.check();
    try provider.check(base.io, peer);
    const source_path = try wire.windowsPath(base.allocator, base.path);
    defer base.allocator.free(source_path);
    const target_path = try wire.windowsPath(base.allocator, context.target.path);
    defer base.allocator.free(target_path);
    const source_root = try @import("file.zig").here(base.dir);
    const target_root = try @import("file.zig").here(context.target.dir);
    if (source_root.device_major != target_root.device_major or source_root.device_minor != target_root.device_minor) return error.CrossDevice;
    var child = try Proxy.spawn(context, peer.executable, peer.bounds.reap);
    errdefer child.close();
    try child.fits();
    return child;
}

pub fn settle(context: Context, peer: ?provider.Provider, record: intent.Record) !void {
    try intent.scope(context, record, record.from, record.to);
    if (try intent.arrived(context, record)) {
        return finish(context, record);
    }
    if (!record.committed) return intent.cancel(context, record);
    try context.validate(record.from);
    const configured = peer orelse return error.NativeMoveUnknown;
    var child = try prepare(context, configured);
    defer child.close();
    try exchange(context, configured, record, &child);
}

fn complete(context: Context, record: intent.Record, status: wire.Status) !void {
    switch (status) {
        .success => {
            if (!try intent.arrived(context, record)) return error.IdentityConflict;
            try finish(context, record);
        },
        .collision => {
            try intent.cancel(context, record);
            return error.PathAlreadyExists;
        },
        .cross_device => {
            try intent.cancel(context, record);
            return error.CrossDevice;
        },
        .refused => {
            try intent.cancel(context, record);
            return error.NativeMoveRefused;
        },
        // The peer's window closed before COMMIT reached it; nothing moved.
        .expired => {
            try intent.cancel(context, record);
            return error.NativeMoveExpired;
        },
    }
}

fn finish(context: Context, record: intent.Record) !void {
    try context.authorized(record.from);
    try context.source.checkMarked();
    try context.target.checkMarked();
    try Context.owned(context.target, record.to);
    try @import("file.zig").syncDir(context.target.dir);
    try @import("file.zig").syncDir(context.source.dir);
    try intent.cleanup(context, record, true);
}

fn exchange(context: Context, peer: provider.Provider, record: intent.Record, child: *Proxy) !void {
    if (builtin.os.tag != .linux) return error.OperationUnsupported;
    const base = context.source;
    const allocator = base.allocator;
    const io = base.io;
    var flagged = record.committed;
    errdefer {
        child.close();
        if (!flagged and child.stage == .reaped) intent.cancel(context, record) catch {};
    }
    try intent.scope(context, record, record.from, record.to);
    try context.validate(record.from);
    if (!std.mem.eql(u8, &peer.sha256, &try provider.digest(io, peer.executable))) return error.PeerDigestMismatch;
    const source = try wire.windowsPath(allocator, base.path);
    defer allocator.free(source);
    const target = try wire.windowsPath(allocator, context.target.path);
    defer allocator.free(target);
    const request: wire.Request = .{ .nonce = record.nonce, .source = .{ .path = source, .marker = try Context.marker(base) }, .target = .{ .path = target, .marker = try Context.marker(context.target) }, .from = record.from, .to = record.to, .commit_ms = peer.bounds.commit, .drain_ms = peer.bounds.drain };
    if (peer.observer) |observer| try observer.report(observer.context, .{ .proxy_pid = 0, .reply = .{ .nonce = record.nonce, .phase = .starting, .pid = 0, .source_inode = 0, .source_root = 0, .target_root = 0 } });
    try wire.write(allocator, io, child.child.stdin.?, request);
    const ready = wire.read(wire.Reply, allocator, io, child.child.stdout.?, .after(io, peer.bounds.ready)) catch |err| return if (err == error.DeadlineExceeded) error.NativePeerTimeout else err;
    defer ready.deinit();
    // The peer opened its window before it wrote this reply, so both bounds
    // here end no earlier than the peer's own.
    const window: Deadline = .after(io, peer.bounds.commit);
    const drained: Deadline = .after(io, peer.bounds.commit + peer.bounds.drain);
    try reply(record, ready.value, .bound);
    if (peer.observer) |observer| try observer.report(observer.context, .{ .proxy_pid = child.child.id.?, .reply = ready.value });
    try context.recheck(record.from, record.source, record.source_root, record.target_root);
    if (window.left(io) == null) return error.NativePeerTimeout;
    try intent.commit(context, record);
    flagged = true;
    child.commit(allocator, .{ .nonce = record.nonce, .commit = true }) catch |err| return complete(context, record, try lost(context, record, err));
    const done = wire.read(wire.Reply, allocator, io, child.child.stdout.?, drained) catch |err| {
        child.close();
        return complete(context, record, try lost(context, record, err));
    };
    defer done.deinit();
    try reply(record, done.value, .done);
    if (done.value.source_inode != ready.value.source_inode or done.value.source_root != ready.value.source_root or done.value.target_root != ready.value.target_root or done.value.pid != ready.value.pid) return error.BadFrame;
    if (peer.observer) |observer| try observer.report(observer.context, .{ .proxy_pid = child.child.id.?, .reply = done.value });
    return outcome(context, record, done.value.status, child.reap());
}

/// A reply is not a cancellation proof without its matching native exit.
/// Success may outlive reap: the verified arrival, checked by complete,
/// settles that result even when the proxy is still draining. A watchdog
/// drain exit is also allowed only for a success reply and verified arrival.
pub fn outcome(context: Context, record: intent.Record, status: wire.Status, term: ?std.process.Child.Term) !void {
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
    try complete(context, record, status);
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

fn reply(record: intent.Record, value: wire.Reply, phase: wire.Phase) !void {
    if (value.version != wire.version or value.phase != phase or value.pid == 0 or !std.mem.eql(u8, &record.nonce, &value.nonce)) return error.BadFrame;
}
