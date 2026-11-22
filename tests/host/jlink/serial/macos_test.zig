const std = @import("std");

const serial_macos = @import("ra8").host.jlink.serial_macos;

test "macOS serial guard admits only J-Link cu.usbmodem callout paths without traversal" {
    try std.testing.expect(serial_macos.allowedCalloutPath("/dev/cu.usbmodem0010833221931"));
    try std.testing.expect(serial_macos.allowedCalloutPath("/dev/cu.usbmodem0010889570271"));
    try std.testing.expect(!serial_macos.allowedCalloutPath("/dev/tty.usbmodem0010833221931"));
    try std.testing.expect(!serial_macos.allowedCalloutPath("/dev/cu.usbmodem"));
    try std.testing.expect(!serial_macos.allowedCalloutPath("/dev/cu.usbmodem001083322193/.."));
    try std.testing.expect(!serial_macos.allowedCalloutPath("/dev/cu.usbmodem001-2"));
    var too_long: [64]u8 = undefined;
    @memcpy(too_long[0..serial_macos.callout_prefix.len], serial_macos.callout_prefix);
    @memset(too_long[serial_macos.callout_prefix.len..], '1');
    try std.testing.expect(!serial_macos.allowedCalloutPath(&too_long));
}
