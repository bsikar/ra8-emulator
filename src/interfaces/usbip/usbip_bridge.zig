//! The live usbip bridge (RA8EMU-75 slice 4c): the socket side of a run,
//! advanced by `poll` at each board boundary so it never blocks the
//! firmware. It waits for the FS device to enumerate, binds 127.0.0.1,
//! accepts a host when one is knocking, and once a host has imported the
//! device it reads that host's URBs and pumps them through the pipes the
//! firmware opened. A host that hangs up leaves the listener open for
//! the next one. Nothing is printed here; the caller reports the events.
const std = @import("std");
const exp = @import("usbip_export.zig");
const board = @import("usbip_board.zig");
const listen = @import("usbip_listen.zig");
const server = @import("usbip_server.zig");
const session = @import("usbip_session.zig");
const usbfs = @import("../../periph/usbfs/usbfs.zig");

/// What one poll changed.
pub const Event = enum { none, listening, attached, hung_up, unusable };

pub const Bridge = struct {
    wanted: u16,
    live: *session.Session,
    exports: [1]exp.Export = undefined,
    listener: ?std.net.Server = null,
    stream: ?std.net.Stream = null,
    given_up: bool = false,

    pub fn init(allocator: std.mem.Allocator, wanted: u16) !Bridge {
        const live = try allocator.create(session.Session);
        live.* = .{};
        return .{ .wanted = wanted, .live = live };
    }

    pub fn deinit(self: *Bridge, allocator: std.mem.Allocator) void {
        if (self.stream) |stream| stream.close();
        if (self.listener) |*listener| listener.deinit();
        allocator.destroy(self.live);
    }

    /// The port the listener is bound to, once it is.
    pub fn port(self: *const Bridge) ?u16 {
        const listener = self.listener orelse return null;
        return listener.listen_address.getPort();
    }

    /// The exported device, once there is one.
    pub fn exported(self: *const Bridge) ?*const exp.Export {
        return if (self.listener == null) null else &self.exports[0];
    }

    /// Advance whatever stage the bridge is in, without waiting.
    pub fn poll(self: *Bridge, device: *usbfs.Device, script: *const usbfs.host.Host) !Event {
        if (self.stream) |stream| return self.traffic(stream, device);
        if (self.listener) |*listener| return self.accept(listener);
        if (self.given_up) return .none;
        return self.offer(script);
    }

    fn offer(self: *Bridge, script: *const usbfs.host.Host) !Event {
        const found = board.fsExport(script) catch {
            self.given_up = true;
            return .unusable;
        } orelse return .none;
        self.exports[0] = found;
        self.listener = try listen.open(self.wanted);
        return .listening;
    }

    fn accept(self: *Bridge, listener: *std.net.Server) !Event {
        if (!readable(listener.stream.handle)) return .none;
        const connection = try listener.accept();
        const imported = server.serve(connection.stream.reader(), connection.stream.writer(), &self.exports) catch null;
        if (imported == null) {
            connection.stream.close();
            return .none;
        }
        self.stream = connection.stream;
        return .attached;
    }

    fn traffic(self: *Bridge, stream: std.net.Stream, device: *usbfs.Device) !Event {
        while (readable(stream.handle)) {
            const more = self.live.receive(stream.reader(), stream.writer()) catch false;
            if (!more) return self.hangUp(stream);
        }
        _ = self.live.pump(device, stream.writer()) catch return self.hangUp(stream);
        return .none;
    }

    fn hangUp(self: *Bridge, stream: std.net.Stream) Event {
        stream.close();
        self.stream = null;
        self.live.* = .{};
        return .hung_up;
    }
};

fn readable(handle: std.posix.socket_t) bool {
    var fds = [_]std.posix.pollfd{.{ .fd = handle, .events = std.posix.POLL.IN, .revents = 0 }};
    const ready = std.posix.poll(&fds, 0) catch return false;
    return ready > 0;
}
