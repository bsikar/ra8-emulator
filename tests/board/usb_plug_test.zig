//! Plugging a disk into the HS jack: blank, from a host image, or refused.
const std = @import("std");
const ra8 = @import("ra8");
const usb = ra8.board.usb;
const usb_plug = ra8.board.usb_plug;

test "blank is a formatted FAT12 volume the device then serves" {
    const disk = try usb_plug.load(std.testing.allocator, usb_plug.blank_spec);
    defer std.testing.allocator.free(disk);
    try std.testing.expectEqual(usb_plug.blank_len, disk.len);
    try std.testing.expectEqualStrings("FAT12   ", disk[54..62]);
    var board_usb = usb.Usb{};
    try std.testing.expect(!board_usb.host.xfer.device.hasDisk());
    usb_plug.plug(&board_usb, disk);
    try std.testing.expect(board_usb.host.xfer.device.hasDisk());
    try std.testing.expectEqual(@as(u32, 512), board_usb.host.xfer.device.storage.blocks());
}

test "an image file is read whole" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "disk.img", .data = &([_]u8{0x7E} ** 1024) });
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "disk.img");
    defer std.testing.allocator.free(path);
    const disk = try usb_plug.load(std.testing.allocator, path);
    defer std.testing.allocator.free(disk);
    try std.testing.expectEqual(@as(usize, 1024), disk.len);
    try std.testing.expectEqual(@as(u8, 0x7E), disk[1023]);
}

test "an image that is not whole sectors is refused" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "odd.img", .data = &([_]u8{0} ** 700) });
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "odd.img");
    defer std.testing.allocator.free(path);
    try std.testing.expectError(error.NotWholeSectors, usb_plug.load(std.testing.allocator, path));
}

test "a missing image file is refused" {
    try std.testing.expectError(error.FileNotFound, usb_plug.load(std.testing.allocator, "/nonexistent/ra8.img"));
}

test "no --usb-disk leaves the echo device in the jack" {
    var board_usb = usb.Usb{};
    try usb_plug.apply(&board_usb, std.testing.allocator, null);
    try std.testing.expect(!board_usb.host.xfer.device.hasDisk());
}
