//! Per-frame HMAC-SHA256 authenticated JSON messages (`SEQ MAC JSON\n`)
//! exchanged over a `RA8PH2` probe-host session: inventory snapshots, claim
//! tokens, chunked ELF staging for remote flashing, streamed progress/UART
//! chunks, and finite operation replies.
const std = @import("std");

const auth = @import("auth.zig");
const sock_ready = @import("../sock/ready.zig");
const targets = @import("../targets.zig");

pub const max_line = 65536;
pub const max_chunks = 64;
pub const max_flash_elf: u32 = 4 * 1024 * 1024;
pub const raw_chunk_bytes: usize = 16384;

pub const Op = enum { list, claim, release, perform, flash_begin, flash_chunk, flash_commit };

pub const Request = struct {
    op: Op,
    probe_id: []const u8 = "",
    board_id: []const u8 = "",
    token: u64 = 0,
    action: targets.Action = .registers,
    total_len: u32 = 0,
    offset: u32 = 0,
    sha256: []const u8 = "",
    hex: []const u8 = "",
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

const ErrorPair = struct { name: []const u8, err: anyerror };

const mapped_errors = [_]ErrorPair{
    .{ .name = "TargetBusy", .err = error.TargetBusy },
    .{ .name = "StaleLease", .err = error.StaleLease },
    .{ .name = "StaleSelection", .err = error.StaleLease },
    .{ .name = "Disconnected", .err = error.Disconnected },
    .{ .name = "AmbiguousIdentity", .err = error.AmbiguousIdentity },
    .{ .name = "NotReserved", .err = error.NotReserved },
    .{ .name = "Unsupported", .err = error.Unsupported },
    .{ .name = "CustodianUnavailable", .err = error.CustodianUnavailable },
    .{ .name = "WrongCore", .err = error.WrongCore },
    .{ .name = "WrongProbe", .err = error.WrongProbe },
    .{ .name = "Canceled", .err = error.Canceled },
    .{ .name = "ProbeTimeout", .err = error.Timeout },
    .{ .name = "Timeout", .err = error.Timeout },
    .{ .name = "NotElf", .err = error.NotElf },
    .{ .name = "InvalidElf", .err = error.InvalidElf },
    .{ .name = "UnsupportedElfTarget", .err = error.UnsupportedElfTarget },
    .{ .name = "EmptyLoadImage", .err = error.EmptyLoadImage },
    .{ .name = "TooManySegments", .err = error.TooManySegments },
    .{ .name = "InvalidFlashWindow", .err = error.InvalidFlashWindow },
    .{ .name = "AddressOutOfRange", .err = error.AddressOutOfRange },
    .{ .name = "BadChecksum", .err = error.BadChecksum },
    .{ .name = "FlashFailed", .err = error.FlashFailed },
    .{ .name = "VerifyFailed", .err = error.VerifyFailed },
};

pub fn mapError(name: []const u8) anyerror {
    for (mapped_errors) |item| {
        if (std.mem.eql(u8, name, item.name)) return item.err;
    }
    return error.ProbeHostFailed;
}
