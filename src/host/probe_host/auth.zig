//! Mutual challenge-response handshake (`RA8PH2`) and per-frame HMAC-SHA256
//! session keys for a probe-host link. Both ends prove possession of the
//! operator-provisioned 256-bit key and bind the exact `host_id` plus fresh
//! 32-byte nonces, deriving directional keys and monotonic sequence counters
//! that authenticate every subsequent frame on the stream.
const std = @import("std");

const pipe = @import("../build/pipe.zig");
const sock_ready = @import("../sock/ready.zig");

const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;

pub const Key = [32]u8;
const Nonce = [32]u8;

pub const Session = struct {
    tx_key: Key,
    rx_key: Key,
    tx_seq: u64 = 0,
    rx_seq: u64 = 0,

    pub fn sign(self: *Session, payload: []const u8) [32]u8 {
        self.tx_seq += 1;
        return frameMac(self.tx_key, self.tx_seq, payload);
    }

    pub fn verify(self: *Session, seq: u64, tag: [32]u8, payload: []const u8) !void {
        const expected_seq = std.math.add(u64, self.rx_seq, 1) catch return error.AuthenticationFailed;
        if (seq != expected_seq) return error.AuthenticationFailed;
        const expected = frameMac(self.rx_key, seq, payload);
        if (!std.crypto.timing_safe.eql([32]u8, tag, expected)) return error.AuthenticationFailed;
        self.rx_seq = expected_seq;
    }
};

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

pub const Source = union(enum) {
    reader: *std.Io.Reader,
    socket: struct { handle: sock_ready.Handle, timeout_ms: u32 = 5_000 },
    pipe: struct { file: std.Io.File, timeout_ms: u32 = 5_000 },

    fn nextLine(self: Source, io: std.Io, out: []u8) ![]const u8 {
        return switch (self) {
            .reader => |r| takeLine(r, out),
            .socket => |s| takeSocketLine(io, s.handle, out, s.timeout_ms),
            .pipe => |p| takePipeLine(io, p.file, out, p.timeout_ms),
        };
    }
};

pub fn authenticateClient(
    io: std.Io,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    host_id: []const u8,
    key: Key,
) !Session {
    return authenticateClientFrom(io, .{ .reader = reader }, writer, host_id, key);
}

pub fn authenticateClientFrom(
    io: std.Io,
    source: Source,
    writer: *std.Io.Writer,
    host_id: []const u8,
    key: Key,
) !Session {
    try checkHost(host_id);
    var client_nonce: Nonce = undefined;
    io.random(&client_nonce);
    try writer.print("RA8PH2 client {s} {x}\n", .{ host_id, &client_nonce });
    try writer.flush();
    var line_buf: [512]u8 = undefined;
    const line = try source.nextLine(io, &line_buf);
    var words = std.mem.tokenizeScalar(u8, line, ' ');
    if (!eqlOpt(words.next(), "RA8PH2") or !eqlOpt(words.next(), "agent")) return error.AuthenticationFailed;
    if (!eqlOpt(words.next(), host_id)) return error.AuthenticationFailed;
    const agent_nonce = try hex32(words.next() orelse return error.AuthenticationFailed);
    const agent_mac = try hex32(words.next() orelse return error.AuthenticationFailed);
    if (words.next() != null or std.mem.eql(u8, &client_nonce, &agent_nonce)) return error.AuthenticationFailed;
    const expected = mac(key, "agent", host_id, client_nonce, agent_nonce);
    if (!std.crypto.timing_safe.eql([32]u8, agent_mac, expected)) return error.AuthenticationFailed;
    const reply = mac(key, "client", host_id, client_nonce, agent_nonce);
    try writer.print("RA8PH2 verify {x}\n", .{&reply});
    try writer.flush();
    const ready = try source.nextLine(io, &line_buf);
    if (!std.mem.eql(u8, ready, "RA8PH2 ready")) return error.AuthenticationFailed;
    return .{
        .tx_key = mac(key, "c2a", host_id, client_nonce, agent_nonce),
        .rx_key = mac(key, "a2c", host_id, client_nonce, agent_nonce),
    };
}

pub fn authenticateAgent(
    io: std.Io,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    host_id: []const u8,
    key: Key,
) !Session {
    return authenticateAgentFrom(io, .{ .reader = reader }, writer, host_id, key);
}

pub fn authenticateAgentFrom(
    io: std.Io,
    source: Source,
    writer: *std.Io.Writer,
    host_id: []const u8,
    key: Key,
) !Session {
    try checkHost(host_id);
    var line_buf: [512]u8 = undefined;
    const hello = try source.nextLine(io, &line_buf);
    var words = std.mem.tokenizeScalar(u8, hello, ' ');
    if (!eqlOpt(words.next(), "RA8PH2") or !eqlOpt(words.next(), "client")) return error.AuthenticationFailed;
    if (!eqlOpt(words.next(), host_id)) return error.AuthenticationFailed;
    const client_nonce = try hex32(words.next() orelse return error.AuthenticationFailed);
    if (words.next() != null) return error.AuthenticationFailed;
    var agent_nonce: Nonce = undefined;
    io.random(&agent_nonce);
    if (std.mem.eql(u8, &client_nonce, &agent_nonce)) agent_nonce[0] ^= 1;
    const proof = mac(key, "agent", host_id, client_nonce, agent_nonce);
    try writer.print("RA8PH2 agent {s} {x} {x}\n", .{ host_id, &agent_nonce, &proof });
    try writer.flush();
    const verify_line = try source.nextLine(io, &line_buf);
    var check = std.mem.tokenizeScalar(u8, verify_line, ' ');
    if (!eqlOpt(check.next(), "RA8PH2") or !eqlOpt(check.next(), "verify")) return error.AuthenticationFailed;
    const client_mac = try hex32(check.next() orelse return error.AuthenticationFailed);
    if (check.next() != null) return error.AuthenticationFailed;
    const expected = mac(key, "client", host_id, client_nonce, agent_nonce);
    if (!std.crypto.timing_safe.eql([32]u8, client_mac, expected)) return error.AuthenticationFailed;
    try writer.writeAll("RA8PH2 ready\n");
    try writer.flush();
    return .{
        .tx_key = mac(key, "a2c", host_id, client_nonce, agent_nonce),
        .rx_key = mac(key, "c2a", host_id, client_nonce, agent_nonce),
    };
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

pub fn takePipeLine(io: std.Io, file: std.Io.File, out: []u8, timeout_ms: u32) ![]const u8 {
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + @as(i96, timeout_ms) * std.time.ns_per_ms;
    var len: usize = 0;
    while (true) {
        if (std.Io.Clock.awake.now(io).nanoseconds >= deadline) return error.Timeout;
        var byte: [1]u8 = undefined;
        const got = (pipe.read(io, file, &byte) catch return error.AgentDisconnected) orelse {
            try std.Io.sleep(io, .fromMilliseconds(2), .awake);
            continue;
        };
        if (got == 0) return error.AgentDisconnected;
        if (byte[0] == '\n') return std.mem.trimEnd(u8, out[0..len], "\r");
        if (len == out.len) return error.FrameTooLong;
        out[len] = byte[0];
        len += 1;
    }
}

pub fn hex32(word: []const u8) ![32]u8 {
    if (word.len != 64) return error.AuthenticationFailed;
    var out: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, word) catch return error.AuthenticationFailed;
    return out;
}

fn frameMac(key: Key, seq: u64, payload: []const u8) [32]u8 {
    var seq_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &seq_bytes, seq, .little);
    var state = Hmac.init(&key);
    state.update("RA8PH2:frame:");
    state.update(&seq_bytes);
    state.update(payload);
    var digest: [32]u8 = undefined;
    state.final(&digest);
    return digest;
}

fn mac(key: Key, role: []const u8, host_id: []const u8, client_nonce: Nonce, agent_nonce: Nonce) [32]u8 {
    var state = Hmac.init(&key);
    state.update("RA8PH2:");
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
