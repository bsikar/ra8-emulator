//! Immutable provenance of a root-level lease. Liveness remains its OS lock.
const std = @import("std");
const metadata = @import("metadata.zig");
const machine = @import("machine.zig");
const name = @import("name.zig");

pub const max_bytes = 16384;
pub const Record = struct {
    version: u32,
    id: name.Id,
    nonce: name.Id,
    host: []const u8,
    root_path: []const u8,
    root_inode: u64,
};

pub fn write(io: std.Io, root: std.Io.Dir, held: std.Io.File, id: []const u8) !void {
    var host: [machine.limits.host]u8 = undefined;
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const local = machine.hostName(&host);
    if (std.mem.eql(u8, local, machine.unknown)) return error.UnknownHost;
    const length = try root.realPath(io, &path);
    const record: Record = .{ .version = 1, .id = try name.id(id), .nonce = name.newId(io), .host = local, .root_path = path[0..length], .root_inode = @intCast((try root.stat(io)).inode) };
    const text = try std.json.Stringify.valueAlloc(std.heap.page_allocator, record, .{});
    defer std.heap.page_allocator.free(text);
    if (text.len > max_bytes) return error.BadLease;
    try metadata.ordinary(try held.stat(io));
    try held.writeStreamingAll(io, text);
    try held.sync(io);
}

pub fn validate(io: std.Io, root: std.Io.Dir, held: std.Io.File, id: []const u8) !void {
    const stat = try held.stat(io);
    try metadata.ordinary(stat);
    if (stat.size == 0 or stat.size > max_bytes) return error.BadLease;
    var bytes: [max_bytes]u8 = undefined;
    const count = try held.readPositionalAll(io, bytes[0..@intCast(stat.size)], 0);
    if (count != stat.size) return error.BadLease;
    const parsed = try std.json.parseFromSlice(Record, std.heap.page_allocator, bytes[0..count], .{});
    defer parsed.deinit();
    const record = parsed.value;
    if (record.version != 1 or !name.isId(&record.nonce) or !std.mem.eql(u8, &record.id, id)) return error.BadLease;
    var host: [machine.limits.host]u8 = undefined;
    const local = machine.hostName(&host);
    if (std.mem.eql(u8, local, machine.unknown) or !std.mem.eql(u8, local, record.host)) return error.OtherHost;
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const length = try root.realPath(io, &path);
    if (!std.mem.eql(u8, path[0..length], record.root_path) or record.root_inode != (try root.stat(io)).inode) return error.BadLease;
}

pub fn nonce(io: std.Io, root: std.Io.Dir, id: []const u8) !name.Id {
    var leaf: name.Buffer = undefined;
    const held = try metadata.open(io, root, name.lease(&leaf, id), .read_only);
    defer held.close(io);
    try validate(io, root, held, id);
    var bytes: [max_bytes]u8 = undefined;
    const count = try held.readPositionalAll(io, &bytes, 0);
    const parsed = try std.json.parseFromSlice(Record, std.heap.page_allocator, bytes[0..count], .{});
    defer parsed.deinit();
    return parsed.value.nonce;
}
