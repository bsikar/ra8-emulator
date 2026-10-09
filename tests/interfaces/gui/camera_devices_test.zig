//! Covers src/interfaces/gui/camera_devices.zig: the host's video nodes listed by
//! number for the camera panel, in the form `webcam:N` opens.
const std = @import("std");
const ra8 = @import("ra8");

const devices = ra8.gui.camera_devices;
const consent = ra8.host.camera.consent;

test "only videoN names are webcams" {
    try std.testing.expectEqual(@as(?u32, 0), devices.number("video0"));
    try std.testing.expectEqual(@as(?u32, 12), devices.number("video12"));
    try std.testing.expectEqual(@as(?u32, null), devices.number("video"));
    try std.testing.expectEqual(@as(?u32, null), devices.number("video1a"));
    try std.testing.expectEqual(@as(?u32, null), devices.number("vbi0"));
    try std.testing.expectEqual(@as(?u32, null), devices.number("media0"));
    try std.testing.expectEqual(@as(?u32, null), devices.number("video256"));
}

test "a directory's nodes list lowest number first" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    for ([_][]const u8{ "video10", "video2", "vbi0", "video0", "tty1" }) |name| {
        (try tmp.dir.createFile(std.testing.io, name, .{})).close(std.testing.io);
    }
    var found = try devices.list(std.testing.allocator, std.testing.io, tmp.dir);
    defer found.deinit();
    try std.testing.expectEqualSlices(u32, &.{ 0, 2, 10 }, found.numbers);
}

test "an empty directory has no webcams" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var found = try devices.list(std.testing.allocator, std.testing.io, tmp.dir);
    defer found.deinit();
    try std.testing.expectEqual(@as(usize, 0), found.numbers.len);
}

test "a listed device opens the node it came from" {
    var arg_buf: [8]u8 = undefined;
    const arg = try devices.argument(&arg_buf, 10);
    try std.testing.expectEqualStrings("10", arg);
    var dev_buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("/dev/video10", try consent.device(&dev_buf, arg));
}

test "the host list never fails for want of devices" {
    var found = try devices.listHost(std.testing.allocator, std.testing.io);
    defer found.deinit();
    for (found.numbers) |n| try std.testing.expect(n <= devices.max_number);
}
