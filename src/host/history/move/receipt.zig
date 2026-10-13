//! Immutable per-directory intent and destination provenance. Empty
//! directories without this proof are never adopted or removed.
const std = @import("std");
const h = @import("../root.zig");
const file = @import("file.zig");
pub const origin = "move-origin";
pub const ready = "move-ready";
pub const max_bytes = 1024 * 1024;
pub const Entry = struct { name: []const u8, id: file.State };
pub const Record = struct {
    version: u32,
    nonce: h.name.Id,
    host: []const u8,
    from_parent: file.State,
    to_parent: file.State,
    source: file.State,
    target: ?file.State,
    from: []const u8,
    to: []const u8,
    to_path: []const u8,
    purpose: []const u8,
    marker: file.State,
    owner_host: []const u8,
    entries: []const Entry,
    internal: []const Entry,
};

pub fn internal(leaf: []const u8) bool {
    return std.mem.eql(u8, leaf, h.layout.files.moving) or std.mem.eql(u8, leaf, origin) or std.mem.eql(u8, leaf, ready);
}

pub fn read(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, leaf: []const u8) !std.json.Parsed(Record) {
    const held = try h.metadata.open(io, dir, leaf, .read_only);
    defer held.close(io);
    const size = (try held.stat(io)).size;
    if (size == 0 or size > max_bytes) return error.BadReceipt;
    const bytes = try allocator.alloc(u8, @intCast(size));
    defer allocator.free(bytes);
    if (try held.readPositionalAll(io, bytes, 0) != size) return error.BadReceipt;
    const parsed = try std.json.parseFromSlice(Record, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try validate(parsed.value);
    if (!parsed.value.marker.same(try file.opened(held))) return error.IdentityConflict;
    return parsed;
}

pub fn write(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, leaf: []const u8, value: Record) !void {
    const held = try dir.createFile(io, leaf, .{ .read = true, .exclusive = true, .resolve_beneath = true });
    defer held.close(io);
    var record = value;
    record.marker = try file.opened(held);
    try validate(record);
    const bytes = try std.json.Stringify.valueAlloc(allocator, record, .{});
    defer allocator.free(bytes);
    if (bytes.len > max_bytes) return error.BadReceipt;
    try held.writeStreamingAll(io, bytes);
    try held.sync(io);
    try file.syncDir(dir);
}

fn validate(record: Record) !void {
    if (record.version != 1 or !h.name.isId(&record.nonce) or record.host.len == 0) return error.BadReceipt;
    if (record.from_parent.kind != .directory or record.to_parent.kind != .directory or record.source.kind != .directory) return error.BadReceipt;
    if (record.marker.kind != .file or record.marker.links != 1) return error.BadReceipt;
    if (record.target) |target| if (target.kind != .directory) return error.BadReceipt;
    _ = try h.name.component(record.from);
    _ = try h.name.component(record.to);
    if (!std.fs.path.isAbsolute(record.to_path)) return error.BadReceipt;
    if (record.entries.len > 4096 or record.internal.len > 2 or record.purpose.len > 512) return error.BadReceipt;
    for (record.entries, 0..) |entry, index| {
        _ = try h.name.component(entry.name);
        if (internal(entry.name) or entry.id.kind == .other) return error.BadReceipt;
        if (entry.id.kind == .file and entry.id.links != 1) return error.BadReceipt;
        for (record.entries[0..index]) |prior| if (std.mem.eql(u8, prior.name, entry.name)) return error.BadReceipt;
    }
    for (record.internal) |entry| {
        if (!internal(entry.name) or std.mem.eql(u8, entry.name, h.layout.files.moving) or entry.id.kind != .file or entry.id.links != 1) return error.BadReceipt;
    }
}

pub fn scope(record: Record, source_parent: std.Io.Dir, from: []const u8, target_parent: std.Io.Dir, to: []const u8) !void {
    if (!std.mem.eql(u8, from, record.from) or !std.mem.eql(u8, to, record.to)) return error.IdentityConflict;
    if (!record.from_parent.same(try file.here(source_parent)) or !record.to_parent.same(try file.here(target_parent))) return error.IdentityConflict;
    if (!record.source.same(try file.state(source_parent, from))) return error.IdentityConflict;
}

pub fn pair(source: Record, target: Record, actual: file.State) !void {
    const bound = target.target orelse return error.BadReceipt;
    if (!bound.same(actual) or !source.source.same(target.source)) return error.IdentityConflict;
    if (!std.mem.eql(u8, &source.nonce, &target.nonce) or !std.mem.eql(u8, source.host, target.host)) return error.IdentityConflict;
    if (!source.from_parent.same(target.from_parent) or !source.to_parent.same(target.to_parent)) return error.IdentityConflict;
    if (!std.mem.eql(u8, source.from, target.from) or !std.mem.eql(u8, source.to, target.to) or !std.mem.eql(u8, source.purpose, target.purpose)) return error.IdentityConflict;
    if (!std.mem.eql(u8, source.to_path, target.to_path)) return error.IdentityConflict;
    if (source.entries.len != target.entries.len) return error.IdentityConflict;
    for (source.entries, target.entries) |a, b| if (!std.mem.eql(u8, a.name, b.name) or !a.id.same(b.id)) return error.IdentityConflict;
    if (!std.mem.eql(u8, source.owner_host, target.owner_host) or source.internal.len != target.internal.len) return error.IdentityConflict;
    for (source.internal, target.internal) |a, b| if (!std.mem.eql(u8, a.name, b.name) or !a.id.same(b.id)) return error.IdentityConflict;
}

pub fn start(allocator: std.mem.Allocator, io: std.Io, source_parent: std.Io.Dir, from: []const u8, target_parent: std.Io.Dir, to: []const u8, purpose: []const u8, nonce: ?h.name.Id) !void {
    _ = try h.name.component(from);
    _ = try h.name.component(to);
    var source = try source_parent.openDir(io, from, .{ .iterate = true, .follow_symlinks = false });
    defer source.close(io);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var entries: std.ArrayList(Entry) = .empty;
    var internals: std.ArrayList(Entry) = .empty;
    var iterator = source.iterate();
    while (try iterator.next(io)) |entry| {
        const id = try file.state(source, entry.name);
        if (id.kind == .other or (id.kind == .file and id.links != 1)) return error.UnexpectedKind;
        if (internal(entry.name)) {
            if (std.mem.eql(u8, entry.name, h.layout.files.moving)) return error.Moving;
            try h.metadata.ordinary(try source.statFile(io, entry.name, .{ .follow_symlinks = false }));
            try internals.append(alloc, .{ .name = try alloc.dupe(u8, entry.name), .id = id });
        } else try entries.append(alloc, .{ .name = try alloc.dupe(u8, entry.name), .id = id });
    }
    var host: [h.machine.limits.host]u8 = undefined;
    var owner_bytes: [h.owner.max_bytes]u8 = undefined;
    var owner_host: []const u8 = "";
    for (entries.items) |entry| if (std.mem.eql(u8, entry.name, h.layout.files.owner)) {
        owner_host = (try h.owner.read(io, source, &owner_bytes)).host;
    };
    const state = try file.here(source);
    if (!state.same(try file.state(source_parent, from))) return error.IdentityConflict;
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try target_parent.realPath(io, &path);
    const found = h.name.classify(from);
    const token = nonce orelse if (found.id.len != 0) try h.lease.nonce(io, source_parent, found.id) else h.name.newId(io);
    try write(allocator, io, source, h.layout.files.moving, .{
        .version = 1,
        .nonce = token,
        .host = h.machine.hostName(&host),
        .from_parent = try file.here(source_parent),
        .to_parent = try file.here(target_parent),
        .source = state,
        .target = null,
        .from = from,
        .to = to,
        .to_path = path[0..path_len],
        .purpose = purpose,
        .marker = undefined,
        .owner_host = owner_host,
        .entries = entries.items,
        .internal = internals.items,
    });
}

pub fn anchorName(buffer: *[h.name.limits.component]u8, from: []const u8) ![]const u8 {
    const found = h.name.classify(from);
    return std.fmt.bufPrint(buffer, "{s}.departure", .{if (found.id.len == 0) from else found.id});
}

/// Recovery-only alias read. Ordinary owner metadata still requires one
/// link. Exactly the recorded inode, both names, and this nonce-bound target
/// proof authorize the transient two-link state.
pub fn localOwner(allocator: std.mem.Allocator, io: std.Io, source_parent: std.Io.Dir, from: []const u8, target_parent: std.Io.Dir, to: []const u8) !bool {
    var source = try source_parent.openDir(io, from, .{ .follow_symlinks = false });
    defer source.close(io);
    const parsed = try read(allocator, io, source, h.layout.files.moving);
    defer parsed.deinit();
    const record = parsed.value;
    try scope(record, source_parent, from, target_parent, to);
    var host: [h.machine.limits.host]u8 = undefined;
    const local = h.machine.hostName(&host);
    if (std.mem.eql(u8, local, h.machine.unknown) or !std.mem.eql(u8, local, record.host) or !std.mem.eql(u8, local, record.owner_host)) return false;
    var expected: ?file.State = null;
    for (record.entries) |entry| if (std.mem.eql(u8, entry.name, h.layout.files.owner)) {
        expected = entry.id;
    };
    const id = expected orelse return false;
    const source_state = file.state(source, h.layout.files.owner) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (source_state) |state| {
        if (!id.same(state)) return false;
        if (state.links == 1) return ownerAt(io, source, id, 1, local);
        if (state.links != 2) return false;
    }
    var target = try target_parent.openDir(io, to, .{ .follow_symlinks = false });
    defer target.close(io);
    const arrived = try read(allocator, io, target, origin);
    defer arrived.deinit();
    try pair(record, arrived.value, try file.here(target));
    const target_state = try file.state(target, h.layout.files.owner);
    if (!id.same(target_state)) return false;
    const links: u32 = if (source_state == null) 1 else 2;
    if (target_state.links != links) return false;
    return ownerAt(io, target, id, links, local);
}

fn ownerAt(io: std.Io, dir: std.Io.Dir, expected: file.State, links: u32, local: []const u8) !bool {
    const before = try file.state(dir, h.layout.files.owner);
    if (!expected.same(before) or before.links != links) return false;
    const held = try dir.openFile(io, h.layout.files.owner, .{ .follow_symlinks = false, .resolve_beneath = true });
    defer held.close(io);
    const opened = try file.opened(held);
    if (!expected.same(opened) or opened.links != links) return false;
    const size = (try held.stat(io)).size;
    if (size > h.owner.max_bytes) return false;
    var bytes: [h.owner.max_bytes]u8 = undefined;
    const count = try held.readPositionalAll(io, bytes[0..@intCast(size)], 0);
    if (count != size) return false;
    const after = try file.state(dir, h.layout.files.owner);
    if (!expected.same(after) or after.links != links) return false;
    const owner = h.owner.parse(bytes[0..count]) catch return false;
    return std.mem.eql(u8, owner.host, local);
}
