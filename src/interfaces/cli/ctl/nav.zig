//! Navigation and reverse play commands for `ctl` (Slice 22.4).
const std = @import("std");
const proto = @import("ra8_rpc").session.rpc;
const Client = @import("client.zig").Client;

pub const PlayCmd = struct {
    dir: proto.Direction = .fwd,
    speed: ?f64 = null,
};

pub fn parsePlay(args: []const []const u8) !PlayCmd {
    var dir: proto.Direction = .fwd;
    var speed: ?f64 = null;
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--dir=")) {
            const val = arg[6..];
            if (std.mem.eql(u8, val, "back") or std.mem.eql(u8, val, "backward")) {
                dir = .back;
            } else if (std.mem.eql(u8, val, "fwd") or std.mem.eql(u8, val, "forward")) {
                dir = .fwd;
            } else return error.BadArguments;
        } else if (std.mem.startsWith(u8, arg, "--speed=")) {
            const val = arg[8..];
            speed = std.fmt.parseFloat(f64, val) catch return error.BadArguments;
        } else if (std.mem.eql(u8, arg, "back") or std.mem.eql(u8, arg, "backward")) {
            dir = .back;
        } else if (std.fmt.parseFloat(f64, arg)) |s| {
            speed = s;
        } else |_| return error.BadArguments;
    }
    return .{ .dir = dir, .speed = speed };
}

pub fn parseSeek(allocator: std.mem.Allocator, args: []const []const u8) ![]const u8 {
    if (args.len == 0) return error.BadArguments;
    if (args.len == 1) return args[0];
    if (std.mem.eql(u8, args[0], "marker")) {
        // `marker NAME N` is the Nth arrival, which only an armed marker has.
        if (args.len == 3) return try std.fmt.allocPrint(allocator, "marker {s} {s}", .{ args[1], args[2] });
        return try std.fmt.allocPrint(allocator, "bm {s}", .{args[1]});
    }
    return try std.mem.join(allocator, " ", args);
}

pub fn runPlay(client: *Client, w: anytype, json: bool, cmd: PlayCmd) !void {
    const milli: u64 = if (cmd.speed) |s| @intFromFloat(s * 1000.0) else 0;
    _ = try client.call(proto.Ack, proto.PlayArgs, .play, .{ .dir = cmd.dir, .speed_milli = milli });
    const dir_str = if (cmd.dir == .back) "back" else "fwd";
    if (json) {
        try w.print("{{\"play\":\"{s}\"}}\n", .{dir_str});
    } else {
        try w.print("play {s} accepted\n", .{dir_str});
    }
}

pub fn runSeek(client: *Client, w: anytype, json: bool, target: []const u8) !void {
    _ = try client.call(proto.Ack, proto.Seek, .seek, .{ .target = target });
    if (json) {
        try w.print("{{\"seek\":{f}}}\n", .{std.json.fmt(target, .{})});
    } else {
        try w.print("seek to {s} accepted\n", .{target});
    }
}

/// `nav KIND [ARG]`: what the navigation index holds of one kind.
pub const NavQuery = struct {
    kind: proto.NavQueryKind,
    index: u64 = 0,
    name: []const u8 = "",
};

pub fn parseNav(args: []const []const u8) !NavQuery {
    if (args.len == 0 or args.len > 2) return error.BadArguments;
    const kind = std.meta.stringToEnum(proto.NavQueryKind, args[0]) orelse
        if (std.mem.eql(u8, args[0], "iter")) proto.NavQueryKind.iteration else return error.BadArguments;
    var query: NavQuery = .{ .kind = kind };
    if (args.len == 2) {
        if (kind == .marker) query.name = args[1] else query.index = std.fmt.parseInt(u64, args[1], 10) catch return error.BadArguments;
    }
    return query;
}

pub fn runNav(client: *Client, w: anytype, json: bool, query: NavQuery) !void {
    const got = try client.call(proto.NavQueryResult, proto.NavQueryArgs, .nav_query, .{ .kind = query.kind, .index = query.index, .name = query.name });
    if (json) {
        try w.print("{{\"found\":{d},\"count\":{d},\"branch\":{d},\"r\":{d},\"o\":{d}}}\n", .{ got.found, got.count, got.branch, got.r, got.o });
    } else if (got.found == 0) {
        try w.print("none ({d} indexed)\n", .{got.count});
    } else {
        try w.print("{d} indexed; at {d}:{d}:{d}\n", .{ got.count, got.branch, got.r, got.o });
    }
}

pub fn runFrameStatus(client: *Client, w: anytype, json: bool) !void {
    const got = try client.call(proto.FrameStatusResult, proto.CoreOnly, .frame_status, .{ .core = .cpu0 });
    if (json) {
        try w.print("{{\"ram_bytes\":{d},\"disk_bytes\":{d},\"queue_bytes\":{d},\"frames\":{d},\"decoded_segments\":{d}}}\n", .{ got.ram_bytes, got.disk_bytes, got.queue_bytes, got.frames, got.decoded_segments });
    } else {
        try w.print("frames {d}; cache ram {d} B, disk {d} B; queue {d} B; {d} segment(s) decoded\n", .{ got.frames, got.ram_bytes, got.disk_bytes, got.queue_bytes, got.decoded_segments });
    }
}

/// `marker set NAME PLACE`: arm a marker after recording.
pub const MarkerSet = struct {
    name: []const u8,
    place: []const u8,
};

pub fn runMarkerSet(client: *Client, w: anytype, json: bool, cmd: MarkerSet) !void {
    const armed = try client.call(proto.NavQueryResult, proto.MarkerSetArgs, .marker_set, .{ .name = cmd.name, .place = cmd.place });
    if (json) {
        try w.print("{{\"marker\":{f},\"arrivals\":{d}}}\n", .{ std.json.fmt(cmd.name, .{}), armed.count });
    } else {
        try w.print("marker {s} armed at {s}: {d} arrival(s)\n", .{ cmd.name, cmd.place, armed.count });
    }
}
