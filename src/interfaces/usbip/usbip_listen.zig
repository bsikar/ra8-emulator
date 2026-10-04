//! The usbip socket (RA8EMU-75 slice 3b): accept hosts on a loopback TCP
//! port and run the operation phase on each until one imports a device.
//! A host lists on one connection and imports on the next, so a listing
//! closes its connection and the next accept follows.
const std = @import("std");
const exp = @import("usbip_export.zig");
const server = @import("usbip_server.zig");

/// The port usbip hosts dial by default.
pub const default_port: u16 = 3240;

/// A host that imported an export. URB traffic follows on `stream`.
pub const Attached = struct {
    stream: std.net.Stream,
    item: *const exp.Export,
};

/// Bind 127.0.0.1:`wanted`. Port 0 lets the system pick; read it back from
/// `listen_address`.
pub fn open(wanted: u16) !std.net.Server {
    const address = try std.net.Address.parseIp4("127.0.0.1", wanted);
    return address.listen(.{ .reuse_address = true });
}

/// The port a bound listener ended up on.
pub fn port(listener: *const std.net.Server) u16 {
    return listener.listen_address.getPort();
}

/// Accept hosts until one imports an export. A connection that only
/// lists, asks for an unknown busid, or hangs up is closed and the next
/// one accepted. A malformed request also closes only that connection.
pub fn attach(listener: *std.net.Server, exports: []const exp.Export) !Attached {
    while (true) {
        const connection = try listener.accept();
        const imported = server.serve(connection.stream.reader(), connection.stream.writer(), exports) catch null;
        if (imported) |item| return .{ .stream = connection.stream, .item = item };
        connection.stream.close();
    }
}
