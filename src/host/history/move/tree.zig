//! Native no-replacing movement first, or an owned link/mkdir transaction.
//! Destination origin receipts persist after completion. An unmarked empty
//! directory is ambiguous, never evidence of our interrupted mkdir.
const std = @import("std");
const builtin = @import("builtin");
const h = @import("../root.zig");
const file = @import("file.zig");
const proof = @import("receipt.zig");
const hooks = @import("probe.zig");
const preserve = @import("move.zig").preserve;
pub const limits = struct {
    pub const depth = 8;
    pub const receipt = 512;
};
pub const Probe = hooks.Probe;

pub fn directory(allocator: std.mem.Allocator, io: std.Io, from_dir: std.Io.Dir, from: []const u8, to_dir: std.Io.Dir, to: []const u8, receipt: []const u8) !void {
    return directoryProbed(allocator, io, from_dir, from, to_dir, to, receipt, null);
}
pub fn directoryProbed(allocator: std.mem.Allocator, io: std.Io, from_dir: std.Io.Dir, from: []const u8, to_dir: std.Io.Dir, to: []const u8, receipt: []const u8, probe: ?Probe) !void {
    if (builtin.os.tag == .linux) if (probe) |hook| if (hook.force_fallback) return moveProbed(allocator, io, from_dir, from, to_dir, to, receipt, probe);
    if (try moving(io, from_dir, from)) return moveProbed(allocator, io, from_dir, from, to_dir, to, receipt, probe);
    {
        var source = try from_dir.openDir(io, from, .{ .iterate = true, .follow_symlinks = false });
        defer source.close(io);
        try preflight(io, source, 0);
    }
    try hooks.reach(probe, .native_before, from_dir, from, to_dir, to);
    preserve(io, from_dir, from, to_dir, to) catch |err| switch (err) {
        error.OperationUnsupported => return moveProbed(allocator, io, from_dir, from, to_dir, to, receipt, probe),
        else => return err,
    };
    try hooks.reach(probe, .native_moved, from_dir, from, to_dir, to);
}

pub fn moving(io: std.Io, dir: std.Io.Dir, entry: []const u8) !bool {
    var found = try dir.openDir(io, entry, .{ .follow_symlinks = false });
    defer found.close(io);
    if (present(io, found, h.layout.files.moving)) return true;
    return present(io, found, proof.origin) and !present(io, found, proof.ready);
}
pub fn receiptOf(io: std.Io, dir: std.Io.Dir, entry: []const u8, buffer: *[limits.receipt]u8) ![]const u8 {
    var found = try dir.openDir(io, entry, .{ .follow_symlinks = false });
    defer found.close(io);
    const parsed = try proof.read(std.heap.page_allocator, io, found, h.layout.files.moving);
    defer parsed.deinit();
    if (parsed.value.target != null or parsed.value.purpose.len > buffer.len) return error.BadReceipt;
    @memcpy(buffer[0..parsed.value.purpose.len], parsed.value.purpose);
    return buffer[0..parsed.value.purpose.len];
}

pub fn move(allocator: std.mem.Allocator, io: std.Io, from_dir: std.Io.Dir, from: []const u8, to_dir: std.Io.Dir, to: []const u8, receipt: []const u8) !void {
    return moveProbed(allocator, io, from_dir, from, to_dir, to, receipt, null);
}
pub fn moveProbed(allocator: std.mem.Allocator, io: std.Io, from_dir: std.Io.Dir, from: []const u8, to_dir: std.Io.Dir, to: []const u8, receipt: []const u8, probe: ?Probe) !void {
    if (builtin.os.tag != .linux) return error.OperationUnsupported;
    try level(allocator, io, from_dir, from, to_dir, to, receipt, null, probe, 0);
}

fn level(allocator: std.mem.Allocator, io: std.Io, from_parent: std.Io.Dir, from: []const u8, to_parent: std.Io.Dir, to: []const u8, purpose: []const u8, nonce: ?h.name.Id, probe: ?Probe, depth: usize) anyerror!void {
    if (depth >= limits.depth) return error.TooDeep;
    const leaving = try file.state(from_parent, from);
    const arriving = try file.here(to_parent);
    if (leaving.kind != .directory) return error.NotDir;
    if (leaving.device_major != arriving.device_major or leaving.device_minor != arriving.device_minor) return error.CrossDevice;
    var source = try from_parent.openDir(io, from, .{ .iterate = true, .follow_symlinks = false });
    defer source.close(io);
    const resumed = present(io, source, h.layout.files.moving);
    if (!resumed) {
        try proof.start(allocator, io, from_parent, from, to_parent, to, purpose, nonce);
        try hooks.reach(probe, .source_marked, from_parent, from, to_parent, to);
    }
    const parsed = try proof.read(allocator, io, source, h.layout.files.moving);
    defer parsed.deinit();
    const record = parsed.value;
    try proof.scope(record, from_parent, from, to_parent, to);
    if (nonce) |expected| if (!std.mem.eql(u8, &expected, &record.nonce)) return error.IdentityConflict;
    const made = if (to_parent.createDir(io, to, h.layout.directory_permissions)) |_| true else |err| switch (err) {
        error.PathAlreadyExists => false,
        else => return err,
    };
    if (!made and !resumed) {
        try removeMarker(io, source, h.layout.files.moving, record.marker);
        return error.PathAlreadyExists;
    }
    if (made) {
        try file.syncDir(to_parent);
    }
    var target = try to_parent.openDir(io, to, .{ .iterate = true, .follow_symlinks = false });
    defer target.close(io);
    const target_id = try file.here(target);
    if (!target_id.same(try file.state(to_parent, to))) return error.IdentityConflict;
    if (made) try hooks.reach(probe, .target_created, from_parent, from, to_parent, to);
    if (!target_id.same(try file.state(to_parent, to))) return error.IdentityConflict;
    if (made) {
        var bound = record;
        bound.target = target_id;
        try proof.write(allocator, io, target, proof.origin, bound);
        try hooks.reach(probe, .target_owned, from_parent, from, to_parent, to);
    }
    const arrived = proof.read(allocator, io, target, proof.origin) catch |err| return if (err == error.FileNotFound) error.UnknownReservation else err;
    defer arrived.deinit();
    try proof.pair(record, arrived.value, try file.here(target));
    try h.metadata.ensure(io, target, h.layout.files.moving, "");
    try file.syncDir(target);
    try hooks.reach(probe, .target_marked, from_parent, from, to_parent, to);
    try carry(allocator, io, source, target, record, probe, depth);
    try complete(allocator, io, target, arrived.value, depth);
    try h.metadata.ensure(io, target, proof.ready, "");
    try file.syncDir(target);
    try hooks.reach(probe, .target_ready, from_parent, from, to_parent, to);
    try target.deleteFile(io, h.layout.files.moving);
    try file.syncDir(target);
    try hooks.reach(probe, .target_unmarked, from_parent, from, to_parent, to);
    var anchor_buffer: [h.name.limits.component]u8 = undefined;
    const anchor = try proof.anchorName(&anchor_buffer, from);
    if (depth == 0) try anchorFor(allocator, io, from_parent, anchor, record, arrived.value, target);
    try cleanSource(io, source, record);
    try hooks.reach(probe, .source_unmarked, from_parent, from, to_parent, to);
    if (!record.source.same(try file.state(from_parent, from))) return error.IdentityConflict;
    try from_parent.deleteDir(io, from);
    try file.syncDir(from_parent);
    try hooks.reach(probe, .source_deleted, from_parent, from, to_parent, to);
    if (depth == 0) {
        const saved = try proof.read(allocator, io, from_parent, anchor);
        defer saved.deinit();
        try removeMarker(io, from_parent, anchor, saved.value.marker);
    }
}

fn anchorFor(allocator: std.mem.Allocator, io: std.Io, parent: std.Io.Dir, leaf: []const u8, source: proof.Record, target: proof.Record, dir: std.Io.Dir) !void {
    if (!present(io, parent, leaf)) try proof.write(allocator, io, parent, leaf, target);
    const saved = try proof.read(allocator, io, parent, leaf);
    defer saved.deinit();
    try proof.pair(source, saved.value, try file.here(dir));
}

fn carry(allocator: std.mem.Allocator, io: std.Io, source: std.Io.Dir, target: std.Io.Dir, record: proof.Record, probe: ?Probe, depth: usize) anyerror!void {
    for (record.entries) |entry| {
        const current = file.state(source, entry.name) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (current) |id| {
            if (!entry.id.same(id)) return error.IdentityConflict;
            if (id.kind == .file) {
                try file.settleProbed(source, entry.name, target, entry.name, probe);
            } else {
                if (!try moving(io, source, entry.name) and try endedChild(allocator, io, source, target, entry, record.nonce, depth + 1)) continue;
                try level(allocator, io, source, entry.name, target, entry.name, "child", record.nonce, probe, depth + 1);
            }
        } else if (entry.id.kind == .file) {
            const id = try file.state(target, entry.name);
            if (!entry.id.same(id) or id.links != 1) return error.IdentityConflict;
        } else {
            var child = try target.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false });
            defer child.close(io);
            const bound = try proof.read(allocator, io, child, proof.origin);
            defer bound.deinit();
            if (!bound.value.source.same(entry.id) or !std.mem.eql(u8, &bound.value.nonce, &record.nonce)) return error.IdentityConflict;
            try complete(allocator, io, child, bound.value, depth + 1);
            try h.metadata.expect(io, child, proof.ready, "");
        }
    }
}

fn endedChild(allocator: std.mem.Allocator, io: std.Io, source: std.Io.Dir, target: std.Io.Dir, entry: proof.Entry, nonce: h.name.Id, depth: usize) !bool {
    var child = target.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false }) catch |err| return if (err == error.FileNotFound) false else err;
    defer child.close(io);
    const arrived = proof.read(allocator, io, child, proof.origin) catch |err| return if (err == error.FileNotFound) false else err;
    defer arrived.deinit();
    if (!entry.id.same(arrived.value.source) or !std.mem.eql(u8, &nonce, &arrived.value.nonce)) return error.IdentityConflict;
    try complete(allocator, io, child, arrived.value, depth);
    try h.metadata.expect(io, child, proof.ready, "");
    var remaining = try source.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false });
    defer remaining.close(io);
    var contents = remaining.iterate();
    if (try contents.next(io) != null) return false;
    if (!entry.id.same(try file.state(source, entry.name))) return error.IdentityConflict;
    try source.deleteDir(io, entry.name);
    try file.syncDir(source);
    return true;
}

pub fn finishRecorded(allocator: std.mem.Allocator, io: std.Io, from_parent: std.Io.Dir, target_parent: std.Io.Dir, record: proof.Record) !void {
    if (!record.from_parent.same(try file.here(from_parent)) or !record.to_parent.same(try file.here(target_parent))) return error.IdentityConflict;
    var target = try target_parent.openDir(io, record.to, .{ .iterate = true, .follow_symlinks = false });
    defer target.close(io);
    const arrived = try proof.read(allocator, io, target, proof.origin);
    defer arrived.deinit();
    try proof.pair(record, arrived.value, try file.here(target));
    try h.metadata.expect(io, target, proof.ready, "");
    try complete(allocator, io, target, arrived.value, 0);
    var source = from_parent.openDir(io, record.from, .{ .iterate = true, .follow_symlinks = false }) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer source.close(io);
    if (!record.source.same(try file.here(source))) return error.IdentityConflict;
    if (present(io, source, h.layout.files.moving)) {
        const leaving = try proof.read(allocator, io, source, h.layout.files.moving);
        defer leaving.deinit();
        try proof.pair(leaving.value, record, try file.here(target));
        try cleanSource(io, source, leaving.value);
    }
    var entries = source.iterate();
    if (try entries.next(io) != null) return error.UnexpectedEntry;
    try from_parent.deleteDir(io, record.from);
    try file.syncDir(from_parent);
}

fn complete(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, record: proof.Record, depth: usize) anyerror!void {
    if (depth >= limits.depth) return error.TooDeep;
    const expected = record.target orelse return error.BadReceipt;
    if (!expected.same(try file.here(dir))) return error.IdentityConflict;
    var names = dir.iterate();
    while (try names.next(io)) |entry| {
        if (proof.internal(entry.name)) continue;
        var known = false;
        for (record.entries) |item| if (std.mem.eql(u8, item.name, entry.name)) {
            known = true;
            break;
        };
        if (!known) return error.UnexpectedEntry;
    }
    for (record.entries) |entry| {
        const id = try file.state(dir, entry.name);
        if (entry.id.kind == .file) {
            if (!entry.id.same(id) or id.links != 1) return error.IdentityConflict;
        } else {
            var child = try dir.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false });
            defer child.close(io);
            const parsed = try proof.read(allocator, io, child, proof.origin);
            defer parsed.deinit();
            if (!entry.id.same(parsed.value.source) or !std.mem.eql(u8, &record.nonce, &parsed.value.nonce)) return error.IdentityConflict;
            if (!record.target.?.same(parsed.value.to_parent)) return error.IdentityConflict;
            try complete(allocator, io, child, parsed.value, depth + 1);
            try h.metadata.expect(io, child, proof.ready, "");
        }
    }
}

fn cleanSource(io: std.Io, dir: std.Io.Dir, record: proof.Record) !void {
    var entries = dir.iterate();
    while (try entries.next(io)) |entry| {
        if (!proof.internal(entry.name)) return error.UnexpectedEntry;
    }
    for (record.internal) |entry| removeMarker(io, dir, entry.name, entry.id) catch |err| if (err != error.FileNotFound) return err;
    try removeMarker(io, dir, h.layout.files.moving, record.marker);
}
fn removeMarker(io: std.Io, dir: std.Io.Dir, leaf: []const u8, expected: file.State) !void {
    const actual = try file.state(dir, leaf);
    if (!expected.same(actual) or actual.links != 1) return error.IdentityConflict;
    try dir.deleteFile(io, leaf);
    try file.syncDir(dir);
}

fn preflight(io: std.Io, dir: std.Io.Dir, depth: usize) anyerror!void {
    if (depth >= limits.depth) return error.TooDeep;
    var entries = dir.iterate();
    while (try entries.next(io)) |entry| {
        _ = try h.name.component(entry.name);
        const before = try dir.statFile(io, entry.name, .{ .follow_symlinks = false });
        if (before.kind == .file) {
            if (before.nlink != 1) return error.UnexpectedLinkCount;
        } else if (before.kind == .directory) {
            var child = try dir.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false });
            defer child.close(io);
            if ((try child.stat(io)).inode != before.inode) return error.IdentityConflict;
            try preflight(io, child, depth + 1);
        } else return error.UnexpectedKind;
    }
}
fn present(io: std.Io, dir: std.Io.Dir, leaf: []const u8) bool {
    _ = dir.statFile(io, leaf, .{ .follow_symlinks = false }) catch return false;
    return true;
}
