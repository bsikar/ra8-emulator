//! The host's webcams for the camera panel's device list (RA8EMU-500).
//!
//! A webcam is a /dev/videoN node. The list holds each N, sorted by
//! number, and `argument` writes it the way `webcam:N` and the panel's
//! `Args.webcam` take it, so a pick from the list opens through the same
//! path the command line does.
const std = @import("std");

/// Where the host keeps its video nodes.
pub const host_dir = "/dev";

/// The largest node number `webcam:N` accepts.
pub const max_number: u32 = std.math.maxInt(u8);

pub const Devices = struct {
    allocator: std.mem.Allocator,
    numbers: []u32,

    pub fn deinit(self: *Devices) void {
        self.allocator.free(self.numbers);
        self.* = undefined;
    }
};

/// The video nodes in `dir`, lowest number first. Names that are not
/// `video` followed by digits, and numbers `webcam:N` cannot name, are
/// left out.
pub fn list(allocator: std.mem.Allocator, dir: std.fs.Dir) !Devices {
    var found: std.ArrayList(u32) = .empty;
    errdefer found.deinit(allocator);
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (number(entry.name)) |n| try found.append(allocator, n);
    }
    const numbers = try found.toOwnedSlice(allocator);
    std.mem.sort(u32, numbers, {}, std.sort.asc(u32));
    return .{ .allocator = allocator, .numbers = numbers };
}

/// The host's webcams. A host with no /dev to read has none.
pub fn listHost(allocator: std.mem.Allocator) !Devices {
    var dir = std.fs.openDirAbsolute(host_dir, .{ .iterate = true }) catch
        return .{ .allocator = allocator, .numbers = try allocator.alloc(u32, 0) };
    defer dir.close();
    return list(allocator, dir);
}

/// N for a `videoN` node name, or null for any other name.
pub fn number(name: []const u8) ?u32 {
    const prefix = "video";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    const digits = name[prefix.len..];
    if (digits.len == 0) return null;
    for (digits) |c| if (!std.ascii.isDigit(c)) return null;
    const n = std.fmt.parseUnsigned(u32, digits, 10) catch return null;
    return if (n <= max_number) n else null;
}

/// Device `n` as the panel's webcam argument, written into `buf`.
pub fn argument(buf: []u8, n: u32) ![]const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{n});
}
