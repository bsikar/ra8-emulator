//! Per-frame HMAC-SHA256 authenticated JSON messages (`SEQ MAC JSON\n`)
//! exchanged over a `RA8PH2` probe-host session: inventory snapshots, claim
//! tokens, streamed progress/UART chunks, and finite operation replies.
const std = @import("std");

const auth = @import("auth.zig");
const sock_ready = @import("../sock/ready.zig");
const targets = @import("../targets.zig");

pub const max_line = 65536;
pub const max_chunks = 64;

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
    chunk: bool = false,
    stream: []const u8 = "",
    err: []const u8 = "",
    token: u64 = 0,
    json: []const u8 = "",
    targets: []const Snapshot = &.{},
};

pub fn send(writer: *std.Io.Writer, session: *auth.Session, value: anytype) !void {
    var payload_buf: [max_line - 128]u8 = undefined;
    var payload_writer: std.Io.Writer = .fixed(&payload_buf);
    try std.json.Stringify.value(value, .{}, &payload_writer);
    const payload = payload_writer.buffered();
    const tag = session.sign(payload);
    try writer.print("{d} {x} {s}\n", .{ session.tx_seq, &tag, payload });
    try writer.flush();
}

pub fn receive(
    comptime T: type,
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    session: *auth.Session,
    scratch: []u8,
) !std.json.Parsed(T) {
    const line = try auth.takeLine(reader, scratch);
    return verifyAndParse(T, allocator, session, line);
}

pub fn receiveSocket(
    comptime T: type,
    allocator: std.mem.Allocator,
    io: std.Io,
    handle: sock_ready.Handle,
    session: *auth.Session,
    scratch: []u8,
    timeout_ms: u32,
) !std.json.Parsed(T) {
    const line = try auth.takeSocketLine(io, handle, scratch, timeout_ms);
    return verifyAndParse(T, allocator, session, line);
}

pub fn receivePipe(
    comptime T: type,
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    session: *auth.Session,
    scratch: []u8,
    timeout_ms: u32,
) !std.json.Parsed(T) {
    const line = try auth.takePipeLine(io, file, scratch, timeout_ms);
    return verifyAndParse(T, allocator, session, line);
}

fn verifyAndParse(
    comptime T: type,
    allocator: std.mem.Allocator,
    session: *auth.Session,
    line: []const u8,
) !std.json.Parsed(T) {
    const sp1 = std.mem.indexOfScalar(u8, line, ' ') orelse return error.AuthenticationFailed;
    const seq = std.fmt.parseInt(u64, line[0..sp1], 10) catch return error.AuthenticationFailed;
    const rest = line[sp1 + 1 ..];
    const sp2 = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.AuthenticationFailed;
    const tag = try auth.hex32(rest[0..sp2]);
    const payload = rest[sp2 + 1 ..];
    try session.verify(seq, tag, payload);
    return std.json.parseFromSlice(T, allocator, payload, .{
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
    if (std.mem.eql(u8, name, "Canceled")) return error.Canceled;
    if (std.mem.eql(u8, name, "ProbeTimeout") or std.mem.eql(u8, name, "Timeout")) return error.Timeout;
    return error.ProbeHostFailed;
}
