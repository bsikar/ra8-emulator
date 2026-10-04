//! `--usbip PORT` (RA8EMU-75 slice 3d): once the run is over, offer the
//! board's FS device to usbip hosts on 127.0.0.1:PORT until one imports
//! it. Both backends call `afterRun` after their report, so the bridge
//! sees the same enumeration whichever core ran the firmware.
const usbfs = @import("../../periph/usbfs/usbfs.zig");
const exp = @import("usbip_export.zig");
const board = @import("usbip_board.zig");
const listen = @import("usbip_listen.zig");

/// Serve the FS device when `port` is set. A device that never finished
/// enumerating, or answered with something that is not a descriptor, is
/// reported and nothing is served.
pub fn afterRun(out: anytype, port: ?u16, script: *const usbfs.host.Host) !void {
    const wanted = port orelse return;
    const found = board.fsExport(script) catch |err| {
        return out.print("usbip: the FS device's descriptors are unusable ({s}); nothing exported\n", .{@errorName(err)});
    };
    const item = found orelse {
        return out.print("usbip: the FS device never finished enumerating; nothing exported\n", .{});
    };
    var listener = try listen.open(wanted);
    defer listener.deinit();
    try offer(out, &listener, item);
}

/// Announce the export on a bound listener and wait for a host to import
/// it. URB traffic is not routed yet, so the imported connection closes.
pub fn offer(out: anytype, listener: *@import("std").net.Server, item: exp.Export) !void {
    try out.print("usbip: exporting {s} ({x:0>4}:{x:0>4}) on 127.0.0.1:{d}\n", .{ item.device.busid, item.device.vendor, item.device.product, listen.port(listener) });
    const exports = [_]exp.Export{item};
    const attached = try listen.attach(listener, &exports);
    defer attached.stream.close();
    try out.print("usbip: a host imported {s}; URB traffic is not routed yet\n", .{attached.item.device.busid});
}
