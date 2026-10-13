//! A native peer borrows the original Linux gates and leases through WSL.
const std = @import("std");
const builtin = @import("builtin");
const wire = @import("wire.zig");
const provider = @import("provider.zig");
const intent = @import("intent.zig");
const Context = @import("context.zig").Context;

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
    if (!std.mem.eql(u8, &peer.sha256, &try provider.digest(io, peer.executable))) return error.PeerDigestMismatch;
    const source = try wire.windowsPath(allocator, base.path);
    defer allocator.free(source);
    const target = try wire.windowsPath(allocator, context.target.path);
    defer allocator.free(target);
    const request: wire.Request = .{ .nonce = record.nonce, .source = .{ .path = source, .marker = try Context.marker(base) }, .target = .{ .path = target, .marker = try Context.marker(context.target) }, .from = record.from, .to = record.to };
    if (peer.observer) |observer| try observer.report(observer.context, .{ .proxy_pid = 0, .reply = .{ .nonce = record.nonce, .phase = .starting, .pid = 0, .source_inode = 0, .source_root = 0, .target_root = 0 } });
    var child = try std.process.spawn(io, .{ .argv = &.{ peer.executable, "--internal-host-move" }, .stdin = .pipe, .stdout = .pipe, .stderr = .ignore, .inherit_files = context.authorities, .inherit_dirs = &.{ base.dir, context.target.dir } });
    var waited = false;
    defer if (!waited) {
        if (child.stdin) |pipe| {
            pipe.close(io);
            child.stdin = null;
        }
        _ = child.wait(io) catch {};
    };
    try wire.write(allocator, io, child.stdin.?, request);
    const ready = try wire.read(wire.Reply, allocator, io, child.stdout.?);
    defer ready.deinit();
    try reply(record, ready.value, .bound);
    if (peer.observer) |observer| try observer.report(observer.context, .{ .proxy_pid = child.id.?, .reply = ready.value });
    try context.recheck(record.from, record.source, record.source_root, record.target_root);
    try wire.write(allocator, io, child.stdin.?, wire.Commit{ .nonce = record.nonce, .commit = true });
    child.stdin.?.close(io);
    child.stdin = null;
    const done = wire.read(wire.Reply, allocator, io, child.stdout.?) catch |err| {
        _ = try child.wait(io);
        waited = true;
        try context.source.checkMarked();
        try context.target.checkMarked();
        if (try intent.arrived(context, record)) return .success;
        return err;
    };
    defer done.deinit();
    try reply(record, done.value, .done);
    if (done.value.source_inode != ready.value.source_inode or done.value.source_root != ready.value.source_root or done.value.target_root != ready.value.target_root or done.value.pid != ready.value.pid) return error.BadFrame;
    if (peer.observer) |observer| try observer.report(observer.context, .{ .proxy_pid = child.id.?, .reply = done.value });
    const term = try child.wait(io);
    waited = true;
    try context.source.checkMarked();
    try context.target.checkMarked();
    if (done.value.status == .success and !term.success()) return error.NativePeerFailed;
    return done.value.status;
}

fn reply(record: intent.Record, value: wire.Reply, phase: wire.Phase) !void {
    if (value.version != wire.version or value.phase != phase or value.pid == 0 or !std.mem.eql(u8, &record.nonce, &value.nonce)) return error.BadFrame;
}
