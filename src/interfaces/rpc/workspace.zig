//! Thin workspace routes onto host file operations; Session owns no host I/O.
const std = @import("std");
const rpc = @import("ra8_rpc_wire");
const host = @import("ra8_host").workspace;
const wire = @import("workspace_wire.zig");
const Context = @import("session/handlers.zig").Context;
const Ack = @import("session/rpc.zig").Ack;
pub const routes = .{
    .{ @backingInt(wire.Method.list), list },   .{ @backingInt(wire.Method.stat), stat },
    .{ @backingInt(wire.Method.read), read },   .{ @backingInt(wire.Method.write), write },
    .{ @backingInt(wire.Method.watch), watch }, .{ @backingInt(wire.Method.unwatch), unwatch },
};

pub fn list(context: *Context, args: wire.List) rpc.Outcome(wire.Page) {
    const root = context.workspace orelse return refuse(wire.Page, error.Unavailable);
    if (args.limit == 0 or args.limit > host.max_page_entries) return .{ .err = .bad_args };
    var entries: [host.max_page_entries]host.Entry = undefined;
    var names: [16_384]u8 = undefined;
    const page = root.list(args.path, args.offset, entries[0..args.limit], &names) catch |err| return refuse(wire.Page, err);
    var out: std.Io.Writer = .fixed(context.scratch[0..@min(context.scratch.len, 65_536)]);
    std.json.Stringify.value(page.entries, .{}, &out) catch |err| return refuse(wire.Page, err);
    return .{ .ok = .{ .offset = args.offset, .count = @intCast(page.entries.len), .more = @intFromBool(page.more), .entries = out.buffered() } };
}

pub fn stat(context: *Context, args: wire.Path) rpc.Outcome(wire.Version) {
    const root = context.workspace orelse return refuse(wire.Version, error.Unavailable);
    return .{ .ok = root.stat(args.path) catch |err| return refuse(wire.Version, err) };
}

pub fn read(context: *Context, args: wire.Read) rpc.Outcome(wire.Contents) {
    const root = context.workspace orelse return refuse(wire.Contents, error.Unavailable);
    if (context.scratch.len < wire.version_bytes or args.length > host.max_file_bytes or args.length > context.scratch.len - wire.version_bytes) return refuse(wire.Contents, error.TooLarge);
    const found = root.read(args.path, args.offset, context.scratch[wire.version_bytes..][0..args.length]) catch |err| return refuse(wire.Contents, err);
    const version = wire.encodeVersion(found.version, context.scratch[0..wire.version_bytes]) catch |err| return refuse(wire.Contents, err);
    return .{ .ok = .{ .version = version, .eof = @intFromBool(found.eof), .bytes = found.bytes } };
}

pub fn write(context: *Context, args: wire.Write) rpc.Outcome(wire.Version) {
    const root = context.workspace orelse return refuse(wire.Version, error.Unavailable);
    const expected = wire.decodeVersion(args.expected) catch return .{ .err = .bad_args };
    return .{ .ok = root.write(args.path, args.bytes, expected) catch |err| return refuse(wire.Version, err) };
}

pub fn watch(context: *Context, args: wire.Path) rpc.Outcome(wire.Watch) {
    const root = context.workspace orelse return refuse(wire.Watch, error.Unavailable);
    var buffer: [host.path.capacity]u8 = undefined;
    const path = host.path.normalize(args.path, &buffer) catch |err| return refuse(wire.Watch, err);
    const version = root.observe(path) catch |err| return refuse(wire.Watch, err);
    return .{ .ok = .{ .id = context.workspace_watches.add(path, version) catch |err| return refuse(wire.Watch, err) } };
}

pub fn unwatch(context: *Context, args: wire.Watch) rpc.Outcome(Ack) {
    if (context.workspace == null) return refuse(Ack, error.Unavailable);
    context.workspace_watches.remove(args.id) catch |err| return refuse(Ack, err);
    return .{ .ok = .{ .accepted = 1 } };
}

fn refuse(comptime T: type, err: anyerror) rpc.Outcome(T) {
    const code: u16 = switch (err) {
        error.Unavailable => wire.codes.unavailable,
        error.InvalidPath, error.SymLinkLoop, error.NotDir => wire.codes.invalid_path,
        error.Conflict, error.WouldBlock => wire.codes.conflict,
        error.TooLarge, error.NoSpaceLeft, error.WriteFailed, error.NameTooLong, error.TooManyWatches, error.TooManyEntries => wire.codes.too_large,
        error.FileNotFound => wire.codes.not_found,
        error.InvalidWatch => wire.codes.invalid_watch,
        error.NotFile => wire.codes.not_file,
        error.BadPage, error.BadOffset => return .{ .err = .bad_args },
        else => wire.codes.io,
    };
    return .{ .err = @fromBackingInt(code) };
}
