//! One host socket behind the C6 bridge: live, live and recorded, or
//! replayed from a tape with no host socket at all (RA8EMU-560).
const std = @import("std");
const tape = @import("esp_tape.zig");
const socket_flags = @import("../../interfaces/socket_flags.zig");

const posix = std.posix;
pub const invalid_socket: posix.socket_t = -1;

pub const Connect = enum { done, pending };

pub const Sock = struct {
    fd: posix.socket_t = invalid_socket,
    writer: ?tape.Writer = null,
    reader: ?tape.Reader = null,
    datagram: bool = false,

    /// Opens a nonblocking socket to `address` (replay opens the tape instead).
    pub fn connect(self: *Sock, run: *tape.Tape, key: tape.Key, address: std.net.Address) !Connect {
        self.datagram = key.proto == .udp;
        if (run.mode == .replay) {
            self.reader = try run.load(key);
            return .done;
        }
        const kind: u32 = if (key.proto == .tcp) posix.SOCK.STREAM else posix.SOCK.DGRAM;
        self.fd = try openSocket(kind);
        errdefer self.close();
        if (run.mode == .record) self.writer = try run.create(key);
        posix.connect(self.fd, &address.any, address.getOsSockLen()) catch |err| switch (err) {
            error.WouldBlock => return .pending,
            else => return err,
        };
        return .done;
    }

    pub fn isOpen(self: *const Sock) bool {
        return self.fd != invalid_socket or self.reader != null;
    }

    /// True once a pending connect has finished; an error means it failed.
    pub fn ready(self: *Sock) !bool {
        if (self.reader != null) return true;
        var descriptors = [_]posix.pollfd{.{ .fd = self.fd, .events = posix.POLL.OUT, .revents = 0 }};
        if (try posix.poll(&descriptors, 0) == 0) return false;
        try posix.getsockoptError(self.fd);
        return true;
    }

    /// Sends guest bytes; a replay checks them against the tape instead.
    pub fn send(self: *Sock, bytes: []const u8) !usize {
        if (self.reader) |*reader| {
            if (!reader.expect(bytes)) return error.ReplayDiverged;
            return bytes.len;
        }
        const sent = try posix.send(self.fd, bytes, sendFlags());
        if (self.writer) |*writer| writer.put(.guest, bytes[0..sent]);
        return sent;
    }

    /// Receives host bytes; 0 is the host's close. A replay answers only
    /// once the guest has sent everything recorded before the answer.
    pub fn recv(self: *Sock, out: []u8, flags: u32) !usize {
        if (self.reader) |*reader| {
            const got = reader.take(out);
            if (got != 0 or (reader.closed() and !self.datagram)) return got;
            return error.WouldBlock;
        }
        const got = try posix.recv(self.fd, out, flags);
        if (self.writer) |*writer| {
            const dir: tape.Dir = if (got == 0 and !self.datagram) .closed else .host;
            writer.put(dir, out[0..@min(got, out.len)]);
        }
        return got;
    }

    pub fn shutdownSend(self: *Sock) !void {
        if (self.reader == null) try posix.shutdown(self.fd, .send);
    }

    pub fn close(self: *Sock) void {
        if (self.fd != invalid_socket) posix.close(self.fd);
        if (self.writer) |*writer| writer.close();
        if (self.reader) |*reader| reader.deinit();
        self.* = .{};
    }
};

fn openSocket(kind: u32) !posix.socket_t {
    const fd = try posix.socket(posix.AF.INET, kind | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC, 0);
    errdefer posix.close(fd);
    if (comptime @hasDecl(posix.SO, "NOSIGPIPE")) {
        const enabled: c_int = 1;
        try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.NOSIGPIPE, std.mem.asBytes(&enabled));
    }
    return fd;
}

fn sendFlags() u32 {
    return socket_flags.nosignal;
}
