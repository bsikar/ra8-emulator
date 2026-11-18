//! Linux names a J-Link's CDC port by its USB serial under /dev/serial/by-id.
const std = @import("std");

const emu_list = @import("../emu_list.zig");

pub const by_id = "/dev/serial/by-id";

pub fn find(io: std.Io, serial: u64, out: []u8) !?[]const u8 {
    var dir = std.Io.Dir.cwd().openDir(io, by_id, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close(io);
    var found: ?[]const u8 = null;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!matches(entry.name, serial)) continue;
        if (found != null) return error.DuplicateSerial;
        found = try std.fmt.bufPrint(out, "{s}/{s}", .{ by_id, entry.name });
    }
    return found;
}

/// Whether a by-id link name is the first interface of the J-Link with `serial`.
pub fn matches(name: []const u8, serial: u64) bool {
    if (!std.mem.startsWith(u8, name, "usb-SEGGER_J-Link")) return false;
    var digits: [20]u8 = undefined;
    var wanted: [40]u8 = undefined;
    const tail = std.fmt.bufPrint(&wanted, "_{s}-if00", .{emu_list.format(serial, &digits)}) catch return false;
    return std.mem.endsWith(u8, name, tail);
}
