//! One host socket behind the C6 bridge: live, live and recorded, or
//! replayed from a tape with no host socket at all (RA8EMU-560).
const std = @import("std");
const tape = @import("esp_tape.zig");
const socket_flags = @import("../../interfaces/socket_flags.zig");
const host = @import("../../interfaces/host_sock.zig");

pub const invalid_socket = host.invalid;
pub const Address = host.Address;

pub const Connect = host.Connect;

pub const Sock = struct {
    fd: host.Fd = invalid_socket,
    writer: ?tape.Writer = null,
    reader: ?tape.Reader = null,
    datagram: bool = false,

    /// Opens a nonblocking socket to `address` (replay opens the tape instead).
    pub fn connect(self: *Sock, run: *tape.Tape, key: tape.Key, address: Address) !Connect {
        self.datagram = key.proto == .udp;
        if (run.mode == .replay) {
            self.reader = try run.load(key);
            return .done;
        }
        self.fd = try host.open(if (key.proto == .tcp) .stream else .datagram);
        errdefer self.close();
        if (run.mode == .record) self.writer = try run.create(key);
        return host.connect(self.fd, address);
    }

    pub fn isOpen(self: *const Sock) bool {
        return self.fd != invalid_socket or self.reader != null;
    }

    /// True once a pending connect has finished; an error means it failed.
    pub fn ready(self: *Sock) !bool {
        if (self.reader != null) return true;
        if (!try host.readyFor(self.fd, .writable)) return false;
        try host.finished(self.fd);
        return true;
    }

    /// Sends guest bytes; a replay checks them against the tape instead.
    pub fn send(self: *Sock, bytes: []const u8) !usize {
        if (self.reader) |*reader| {
            if (!reader.expect(bytes)) return error.ReplayDiverged;
            return bytes.len;
        }
        const sent = try host.send(self.fd, bytes, socket_flags.nosignal);
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
        const got = try host.recv(self.fd, out, flags);
        if (self.writer) |*writer| {
            const dir: tape.Dir = if (got == 0 and !self.datagram) .closed else .host;
            writer.put(dir, out[0..@min(got, out.len)]);
        }
        return got;
    }

    pub fn shutdownSend(self: *Sock) !void {
        if (self.reader == null) try host.shutdownSend(self.fd);
    }

    pub fn close(self: *Sock) void {
        if (self.fd != invalid_socket) host.close(self.fd);
        if (self.writer) |*writer| writer.close();
        if (self.reader) |*reader| reader.deinit();
        self.* = .{};
    }
};
