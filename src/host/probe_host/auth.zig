//! Mutual challenge-response authentication for a probe-host link. Both ends
//! prove possession of the operator-provisioned 256-bit key and agree on the
//! exact `host_id` before any inventory or probe operation crosses the stream.
const std = @import("std");

const sock_ready = @import("../sock/ready.zig");

const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;

pub const Key = [32]u8;
const Nonce = [32]u8;

pub fn readKey(io: std.Io, path: []const u8) !Key {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var raw: [160]u8 = undefined;
    const count = try file.readPositional(io, &.{&raw}, 0);
    const trimmed = std.mem.trim(u8, raw[0..count], " \t\r\n");
    if (trimmed.len != 64) return error.InvalidSecret;
    var key: Key = undefined;
    _ = std.fmt.hexToBytes(&key, trimmed) catch return error.InvalidSecret;
    return key;
}

pub fn authenticateClient(
    io: std.Io,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    host_id: []const u8,
    key: Key,
) !void {
    try checkHost(host_id);
    var client_nonce: Nonce = undefined;
    io.random(&client_nonce);
    try writer.print("RA8PH1 client {s} {x}\n", .{ host_id, &client_nonce });
    try writer.flush();
    var line_buf: [512]u8 = undefined;
    const line = try takeLine(reader, &line_buf);
    var words = std.mem.tokenizeScalar(u8, line, ' ');
    if (!eqlOpt(words.next(), "RA8PH1") or !eqlOpt(words.next(), "agent")) return error.AuthenticationFailed;
    if (!eqlOpt(words.next(), host_id)) return error.AuthenticationFailed;
    const agent_nonce = try hex32(words.next() orelse return error.AuthenticationFailed);
    const agent_mac = try hex32(words.next() orelse return error.AuthenticationFailed);
    if (words.next() != null or std.mem.eql(u8, &client_nonce, &agent_nonce)) return error.AuthenticationFailed;
    const expected = mac(key, "agent", host_id, client_nonce, agent_nonce);
    if (!std.crypto.timing_safe.eql([32]u8, agent_mac, expected)) return error.AuthenticationFailed;
    const reply = mac(key, "client", host_id, client_nonce, agent_nonce);
    try writer.print("RA8PH1 verify {x}\n", .{&reply});
    try writer.flush();
    const ready = try takeLine(reader, &line_buf);
    if (!std.mem.eql(u8, ready, "RA8PH1 ready")) return error.AuthenticationFailed;
}

pub fn authenticateAgent(
    io: std.Io,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    host_id: []const u8,
    key: Key,
) !void {
    try checkHost(host_id);
    var line_buf: [512]u8 = undefined;
    const hello = try takeLine(reader, &line_buf);
    var words = std.mem.tokenizeScalar(u8, hello, ' ');
    if (!eqlOpt(words.next(), "RA8PH1") or !eqlOpt(words.next(), "client")) return error.AuthenticationFailed;
    if (!eqlOpt(words.next(), host_id)) return error.AuthenticationFailed;
    const client_nonce = try hex32(words.next() orelse return error.AuthenticationFailed);
    if (words.next() != null) return error.AuthenticationFailed;
    var agent_nonce: Nonce = undefined;
    io.random(&agent_nonce);
    if (std.mem.eql(u8, &client_nonce, &agent_nonce)) agent_nonce[0] ^= 1;
    const proof = mac(key, "agent", host_id, client_nonce, agent_nonce);
    try writer.print("RA8PH1 agent {s} {x} {x}\n", .{ host_id, &agent_nonce, &proof });
    try writer.flush();
    const verify_line = try takeLine(reader, &line_buf);
    var check = std.mem.tokenizeScalar(u8, verify_line, ' ');
    if (!eqlOpt(check.next(), "RA8PH1") or !eqlOpt(check.next(), "verify")) return error.AuthenticationFailed;
    const client_mac = try hex32(check.next() orelse return error.AuthenticationFailed);
    if (check.next() != null) return error.AuthenticationFailed;
    const expected = mac(key, "client", host_id, client_nonce, agent_nonce);
    if (!std.crypto.timing_safe.eql([32]u8, client_mac, expected)) return error.AuthenticationFailed;
    try writer.writeAll("RA8PH1 ready\n");
    try writer.flush();
}

pub fn takeLine(reader: *std.Io.Reader, out: []u8) ![]const u8 {
    var len: usize = 0;
    while (true) {
        const byte = reader.takeByte() catch return error.AgentDisconnected;
        if (byte == '\n') return std.mem.trimEnd(u8, out[0..len], "\r");
        if (len == out.len) return error.FrameTooLong;
        out[len] = byte;
        len += 1;
    }
}

/// Reads one newline-terminated frame directly from `handle` within `timeout_ms`
/// without `std.Io.net.Stream.Reader`, avoiding Windows `LOCAL_DISCONNECT` logs
/// when a peer drops mid-exchange (RA8EMU-943).
pub fn takeSocketLine(io: std.Io, handle: sock_ready.Handle, out: []u8, timeout_ms: u32) ![]const u8 {
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + @as(i96, timeout_ms) * std.time.ns_per_ms;
    var len: usize = 0;
    while (true) {
        const left = deadline - std.Io.Clock.awake.now(io).nanoseconds;
        if (left <= 0) return error.Timeout;
        const step_ms: i32 = @intCast(@min(@as(i96, 1_000), @max(@as(i96, 1), @divTrunc(left, std.time.ns_per_ms))));
        const ready = sock_ready.wait(io, handle, step_ms) catch return error.AgentDisconnected;
        if (!ready.any()) continue;
        var byte: [1]u8 = undefined;
        const got = sock_ready.takeByte(io, handle, &byte, false) orelse return error.AgentDisconnected;
        if (got == 0) return error.AgentDisconnected;
        if (byte[0] == '\n') return std.mem.trimEnd(u8, out[0..len], "\r");
        if (len == out.len) return error.FrameTooLong;
        out[len] = byte[0];
        len += 1;
    }
}

fn mac(key: Key, role: []const u8, host_id: []const u8, client_nonce: Nonce, agent_nonce: Nonce) [32]u8 {
    var state = Hmac.init(&key);
    state.update("RA8PH1:");
    state.update(role);
    state.update(":");
    state.update(host_id);
    state.update(":");
    state.update(&client_nonce);
    state.update(&agent_nonce);
    var digest: [32]u8 = undefined;
    state.final(&digest);
    return digest;
}

fn hex32(word: []const u8) ![32]u8 {
    if (word.len != 64) return error.AuthenticationFailed;
    var out: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, word) catch return error.AuthenticationFailed;
    return out;
}

fn eqlOpt(word: ?[]const u8, expected: []const u8) bool {
    return if (word) |value| std.mem.eql(u8, value, expected) else false;
}

fn checkHost(host_id: []const u8) !void {
    if (host_id.len == 0 or host_id.len > 128) return error.InvalidIdentity;
    for (host_id) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.' and byte != ':') {
            return error.InvalidIdentity;
        }
    }
}
