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
    try provider.check(base.io, peer);
    const source_path = try wire.windowsPath(base.allocator, base.path);
    defer base.allocator.free(source_path);
    const target_path = try wire.windowsPath(base.allocator, context.target.path);
    defer base.allocator.free(target_path);
    const source_root = try @import("file.zig").here(base.dir);
    const target_root = try @import("file.zig").here(context.target.dir);
    if (source_root.device_major != target_root.device_major or source_root.device_minor != target_root.device_minor) return error.CrossDevice;
    const parsed = try intent.start(base.allocator, context, from, to, purpose);
    defer parsed.deinit();
    try settle(context, peer, parsed.value);
}

pub fn settle(context: Context, peer: ?provider.Provider, record: intent.Record) !void {
    try intent.scope(context, record, record.from, record.to);
    if (try intent.arrived(context, record)) {
        return finish(context, record);
    }
    try context.validate(record.from);
    const status = try exchange(context, peer orelse return error.NativePeerUnavailable, record);
    switch (status) {
        .success => {
            if (!try intent.arrived(context, record)) return error.IdentityConflict;
            try finish(context, record);
        },
        .collision => {
            try intent.cleanup(context, record, false);
            return error.PathAlreadyExists;
        },
        .cross_device => {
            try intent.cleanup(context, record, false);
            return error.CrossDevice;
        },
        .refused => return error.NativeMoveRefused,
        // The peer's window closed before COMMIT reached it; nothing moved.
        .expired => return error.NativeMoveExpired,
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

fn exchange(context: Context, peer: provider.Provider, record: intent.Record) !wire.Status {
    if (builtin.os.tag != .linux) return error.OperationUnsupported;
    const base = context.source;
    const allocator = base.allocator;
    const io = base.io;
    try peer.bounds.check();
    if (!std.mem.eql(u8, &peer.sha256, &try provider.digest(io, peer.executable))) return error.PeerDigestMismatch;
    const source = try wire.windowsPath(allocator, base.path);
    defer allocator.free(source);
    const target = try wire.windowsPath(allocator, context.target.path);
    defer allocator.free(target);
    const request: wire.Request = .{ .nonce = record.nonce, .source = .{ .path = source, .marker = try Context.marker(base) }, .target = .{ .path = target, .marker = try Context.marker(context.target) }, .from = record.from, .to = record.to, .commit_ms = peer.bounds.commit, .drain_ms = peer.bounds.drain };
    if (peer.observer) |observer| try observer.report(observer.context, .{ .proxy_pid = 0, .reply = .{ .nonce = record.nonce, .phase = .starting, .pid = 0, .source_inode = 0, .source_root = 0, .target_root = 0 } });
    var child = try Proxy.spawn(context, peer.executable, peer.bounds.reap);
    defer child.close();
    try child.fits();
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
    child.commit(allocator, .{ .nonce = record.nonce, .commit = true }) catch |err| return lost(context, record, err);
    const done = wire.read(wire.Reply, allocator, io, child.child.stdout.?, drained) catch |err| {
        child.close();
        return lost(context, record, err);
    };
    defer done.deinit();
    try reply(record, done.value, .done);
    if (done.value.source_inode != ready.value.source_inode or done.value.source_root != ready.value.source_root or done.value.target_root != ready.value.target_root or done.value.pid != ready.value.pid) return error.BadFrame;
    if (peer.observer) |observer| try observer.report(observer.context, .{ .proxy_pid = child.child.id.?, .reply = done.value });
    const term = child.reap();
    try context.source.checkMarked();
    try context.target.checkMarked();
    if (done.value.status == .success and (term == null or !term.?.success())) return error.NativePeerFailed;
    return done.value.status;
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
