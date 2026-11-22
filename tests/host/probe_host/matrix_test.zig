const std = @import("std");

const matrix = @import("ra8").host.probe_host.matrix;

test "transport matrix selects Linux USB/IP only where supported and falls back to native agent elsewhere" {
    const win_local = matrix.evaluate(.windows, .windows, .jlink_usb, .same_host, false);
    try std.testing.expectEqual(matrix.Transport.native_local, win_local.chosen);
    try std.testing.expect(!win_local.fallback_used and win_local.supported);

    const win_laptop = matrix.evaluate(.windows, .linux, .jlink_usb, .laptop_attached, true);
    try std.testing.expectEqual(matrix.Transport.usbip_vhci, win_laptop.requested);
    try std.testing.expectEqual(matrix.Transport.native_agent, win_laptop.chosen);
    try std.testing.expect(win_laptop.fallback_used and win_laptop.supported);

    const mac_laptop = matrix.evaluate(.macos, .linux, .jlink_usb, .laptop_attached, true);
    try std.testing.expectEqual(matrix.Transport.native_agent, mac_laptop.chosen);
    try std.testing.expect(mac_laptop.fallback_used);

    const linux_usbip = matrix.evaluate(.linux, .linux, .jlink_usb, .laptop_attached, true);
    try std.testing.expectEqual(matrix.Transport.usbip_vhci, linux_usbip.chosen);
    try std.testing.expect(!linux_usbip.fallback_used and linux_usbip.supported);

    const bootloader = matrix.evaluate(.linux, .linux, .bootloader_serial, .laptop_attached, true);
    try std.testing.expectEqual(matrix.Transport.unsupported, bootloader.chosen);
    try std.testing.expect(!bootloader.supported);

    const mac_server = matrix.evaluate(.macos, .macos, .jlink_usb, .server_attached, false);
    try std.testing.expectEqual(matrix.Transport.native_local, mac_server.chosen);
    try std.testing.expect(std.mem.indexOf(u8, mac_server.driver, "/dev/cu.usbmodem CDC") != null);

    var buf: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try matrix.writeJson(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "native_agent") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "server_attached") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "/dev/cu.usbmodem CDC") != null);
}
