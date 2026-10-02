//! What the scripted host on the USBFS jack got out of the device: how far
//! enumeration went, and the descriptors it was handed on the way.
const std = @import("std");
const usbfs_host = @import("../../periph/usbfs/usbfs_host.zig");

/// Silent until the pull-up put a device on the jack.
pub fn section(host: *const usbfs_host.Host, out: anytype) !void {
    if (host.step == .waiting) return;
    try out.print("USBFS host: enumeration {s}", .{@tagName(host.step)});
    if (host.step != .configured) try out.print(" after {d} boundary(ies) on that step", .{host.waited});
    try out.writeAll("\n");
    try descriptor("device", &host.device, out);
    try descriptor("config", host.configuration(), out);
    if (host.step != .configured) return;
    try out.print("USBFS host: configuration value {d}, status {x:0>2} {x:0>2}\n", .{
        host.config_value[0], host.status[0], host.status[1],
    });
}

/// The bytes as the host received them; nothing when none came back.
fn descriptor(name: []const u8, bytes: []const u8, out: anytype) !void {
    if (bytes[0] == 0) return;
    try out.print("USBFS host: {s} descriptor", .{name});
    for (bytes) |byte| try out.print(" {x:0>2}", .{byte});
    try out.writeAll("\n");
}
