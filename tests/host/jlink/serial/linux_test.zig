const std = @import("std");

const serial_linux = @import("ra8").host.jlink.serial_linux;

test "Linux serial guard admits only J-Link CDC by-id symlinks without traversal" {
    try std.testing.expect(serial_linux.allowedByIdPath("/dev/serial/by-id/usb-SEGGER_J-Link_OB-RA4M2_001083322193-if00"));
    try std.testing.expect(!serial_linux.allowedByIdPath("/dev/serial/by-id/usb-SEGGER_J-Link_OB-RA4M2_001083322193-if02"));
    try std.testing.expect(!serial_linux.allowedByIdPath("/dev/ttyACM0"));
    try std.testing.expect(!serial_linux.allowedByIdPath("/dev/serial/by-id/../ttyS0-if00"));
}
