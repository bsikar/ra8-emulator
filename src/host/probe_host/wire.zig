//! Line-delimited JSON messages exchanged over an authenticated probe-host
//! session: inventory snapshots, fenced lease claims, releases, and actions.
const std = @import("std");

const auth = @import("auth.zig");
const sock_ready = @import("../sock/ready.zig");
const targets = @import("../targets.zig");

pub const max_line = 65536;

pub const Op = enum { list, claim, release, perform };

pub const Request = struct {
    op: Op,
    probe_id: []const u8 = "",
    board_id: []const u8 = "",
    token: u64 = 0,
    action: targets.Action = .registers,
};

pub const Snapshot = struct {
    probe_id: []const u8,
    board_id: []const u8,
    probe_serial: []const u8 = "",
    board_serial: []const u8 = "",
    vendor: []const u8 = "",
    model: []const u8 = "",
    cores: []const u8 = "",
    transport: []const u8,
    connected: bool,
    uart: []const u8 = "",
    disambiguation: []const u8 = "",
    identity_verified: bool = false,
    managed: bool = false,
    operations: []const targets.Action = &.{},
    capabilities: targets.Capabilities = .{},
};

pub const Reply = struct {
    ok: bool,
    err: []const u8 = "",
    token: u64 = 0,
    json: []const u8 = "",
    targets: []const Snapshot = &.{},
};

pub fn send(writer: *std.Io.Writer, value: anytype) !void {
    try std.json.Stringify.value(value, .{}, writer);
    try writer.writeByte('\n');
    try writer.flush();
}

pub fn receive(
    comptime T: type,
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    scratch: []u8,
) !std.json.Parsed(T) {
    const line = try auth.takeLine(reader, scratch);
    return parseJson(T, allocator, line);
}

pub fn receiveSocket(
    comptime T: type,
    allocator: std.mem.Allocator,
    io: std.Io,
    handle: sock_ready.Handle,
    scratch: []u8,
    timeout_ms: u32,
) !std.json.Parsed(T) {
    const line = try auth.takeSocketLine(io, handle, scratch, timeout_ms);
    return parseJson(T, allocator, line);
}

fn parseJson(comptime T: type, allocator: std.mem.Allocator, line: []const u8) !std.json.Parsed(T) {
    return std.json.parseFromSlice(T, allocator, line, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch error.BadFrame;
}

pub fn mapError(name: []const u8) anyerror {
    if (std.mem.eql(u8, name, "TargetBusy")) return error.TargetBusy;
    if (std.mem.eql(u8, name, "StaleLease") or std.mem.eql(u8, name, "StaleSelection")) return error.StaleLease;
    if (std.mem.eql(u8, name, "Disconnected")) return error.Disconnected;
    if (std.mem.eql(u8, name, "AmbiguousIdentity")) return error.AmbiguousIdentity;
    if (std.mem.eql(u8, name, "NotReserved")) return error.NotReserved;
    if (std.mem.eql(u8, name, "Unsupported")) return error.Unsupported;
    if (std.mem.eql(u8, name, "CustodianUnavailable")) return error.CustodianUnavailable;
    if (std.mem.eql(u8, name, "WrongCore")) return error.WrongCore;
    if (std.mem.eql(u8, name, "WrongProbe")) return error.WrongProbe;
    return error.ProbeHostFailed;
}
