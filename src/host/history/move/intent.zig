//! Root-anchored native intent moves with its source, never with a lease.
const std = @import("std");
const h = @import("../root.zig");
const file = @import("file.zig");
const Context = @import("context.zig").Context;
pub const note = "native-moving";
pub const suffix = ".native-move";
pub const Record = struct {
    version: u32 = 1,
    nonce: h.name.Id,
    from_path: []const u8,
    to_path: []const u8,
    from: []const u8,
    to: []const u8,
    purpose: []const u8,
    source: file.State,
    source_root: file.State,
    target_root: file.State,
    anchor: file.State,
    marker: file.State,
};

pub fn leaf(buffer: *h.name.Buffer, id: []const u8) ![]const u8 {
    if (!h.name.isId(id)) return error.BadName;
    return std.fmt.bufPrint(buffer, "{s}{s}", .{ id, suffix });
}

pub fn pending(io: std.Io, root: std.Io.Dir, id: []const u8) bool {
    var buffer: h.name.Buffer = undefined;
    return present(io, root, leaf(&buffer, id) catch return true);
}

pub fn read(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, anchor: bool) !std.json.Parsed(Record) {
    const held = try h.metadata.open(io, dir, path, .read_only);
    defer held.close(io);
    var bytes: [32768]u8 = undefined;
    const size = (try held.stat(io)).size;
    if (size == 0 or size > bytes.len) return error.BadReceipt;
    if (try held.readPositionalAll(io, bytes[0..@intCast(size)], 0) != size) return error.BadReceipt;
    const parsed = std.json.parseFromSlice(Record, allocator, bytes[0..@intCast(size)], .{ .allocate = .alloc_always }) catch |err| return if (err == error.OutOfMemory) err else error.BadReceipt;
    errdefer parsed.deinit();
    const record = parsed.value;
    if (record.version != 1 or !h.name.isId(&record.nonce) or !std.fs.path.isAbsolute(record.from_path) or !std.fs.path.isAbsolute(record.to_path)) return error.BadReceipt;
    _ = try h.name.component(record.from);
    _ = try h.name.component(record.to);
    try names(record);
    if (!(if (anchor) record.anchor else record.marker).same(try file.opened(held))) return error.IdentityConflict;
    return parsed;
}

pub fn start(allocator: std.mem.Allocator, context: Context, from: []const u8, to: []const u8, purpose: []const u8) !std.json.Parsed(Record) {
    const base = context.source;
    const io = base.io;
    try checkNames(base.path, context.target.path, from, to, purpose);
    var buffer: h.name.Buffer = undefined;
    const id = h.name.classify(from).id;
    const anchor_name = try leaf(&buffer, id);
    if (present(io, base.dir, anchor_name)) return read(allocator, io, base.dir, anchor_name, true);
    var source = try base.dir.openDir(io, from, .{ .iterate = true, .follow_symlinks = false });
    defer source.close(io);
    const anchor = try base.dir.createFile(io, anchor_name, .{ .read = true, .exclusive = true });
    defer anchor.close(io);
    const marker = try source.createFile(io, note, .{ .read = true, .exclusive = true });
    defer marker.close(io);
    const record: Record = .{ .nonce = try h.lease.nonce(io, base.dir, id), .from_path = base.path, .to_path = context.target.path, .from = from, .to = to, .purpose = purpose, .source = try file.state(base.dir, from), .source_root = try file.here(base.dir), .target_root = try file.here(context.target.dir), .anchor = try file.opened(anchor), .marker = try file.opened(marker) };
    try names(record);
    const bytes = try std.json.Stringify.valueAlloc(allocator, record, .{});
    defer allocator.free(bytes);
    try marker.writeStreamingAll(io, bytes);
    try marker.sync(io);
    try anchor.writeStreamingAll(io, bytes);
    try anchor.sync(io);
    try file.syncDir(source);
    try file.syncDir(base.dir);
    return read(allocator, io, base.dir, anchor_name, true);
}

pub fn scope(context: Context, record: Record, from: []const u8, to: []const u8) !void {
    try names(record);
    const base = context.source;
    if (!std.mem.eql(u8, base.path, record.from_path) or !std.mem.eql(u8, context.target.path, record.to_path) or !std.mem.eql(u8, from, record.from) or !std.mem.eql(u8, to, record.to)) return error.IdentityConflict;
    if (!record.source_root.same(try file.here(base.dir)) or !record.target_root.same(try file.here(context.target.dir))) return error.IdentityConflict;
    const nonce = try h.lease.nonce(base.io, base.dir, h.name.classify(from).id);
    if (!std.mem.eql(u8, &nonce, &record.nonce)) return error.IdentityConflict;
}

pub fn cleanup(context: Context, record: Record, moved: bool) !void {
    const io = context.source.io;
    const root = if (moved) context.target else context.source;
    const entry = if (moved) record.to else record.from;
    if (!record.source.same(try file.state(root.dir, entry))) return error.IdentityConflict;
    var buffer: h.name.Buffer = undefined;
    const anchor_name = try leaf(&buffer, h.name.classify(record.from).id);
    const anchor = try file.state(context.source.dir, anchor_name);
    if (!record.anchor.same(anchor) or anchor.links != 1) return error.IdentityConflict;
    var dir = try root.dir.openDir(io, entry, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(io);
    if (present(io, dir, note)) {
        const marker = try file.state(dir, note);
        if (!record.marker.same(marker) or marker.links != 1) return error.IdentityConflict;
        try dir.deleteFile(io, note);
        try file.syncDir(dir);
    }
    try context.source.dir.deleteFile(io, anchor_name);
    try file.syncDir(context.source.dir);
}

pub fn arrived(context: Context, record: Record) !bool {
    const source = file.state(context.source.dir, record.from) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    const target = file.state(context.target.dir, record.to) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (source) |state| {
        if (!record.source.same(state)) return error.IdentityConflict;
        return false;
    }
    if (target) |state| if (record.source.same(state)) return true;
    return error.IdentityConflict;
}

fn present(io: std.Io, dir: std.Io.Dir, path: []const u8) bool {
    _ = dir.statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return true;
}

fn names(record: Record) !void {
    return checkNames(record.from_path, record.to_path, record.from, record.to, record.purpose);
}

fn checkNames(from_path: []const u8, to_path: []const u8, from_name: []const u8, to: []const u8, purpose: []const u8) !void {
    const from = h.name.classify(from_name);
    if (!h.name.isId(from.id)) return error.BadReceipt;
    const same_root = std.mem.eql(u8, from_path, to_path);
    if (std.mem.eql(u8, purpose, h.layout.moves.publish)) {
        if (!same_root or from.kind != .creating or !std.mem.eql(u8, to, from.id)) return error.BadReceipt;
    } else if (std.mem.eql(u8, purpose, h.layout.moves.trash)) {
        var buffer: h.name.Buffer = undefined;
        if (!same_root or (from.kind != .creating and from.kind != .session) or !std.mem.eql(u8, to, h.name.trash(&buffer, from.id))) return error.BadReceipt;
    } else if (std.mem.startsWith(u8, purpose, h.layout.moves.keep)) {
        const tail = purpose[h.layout.moves.keep.len..];
        if (from.kind != .session or !std.mem.eql(u8, to, from.id) or tail.len != to_path.len + 1 or !std.mem.startsWith(u8, tail, to_path) or tail[tail.len - 1] != '\n') return error.BadReceipt;
    } else return error.BadReceipt;
}
