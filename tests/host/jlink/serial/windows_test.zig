const std = @import("std");

const serial_windows = @import("ra8").host.jlink.serial_windows;

test "Windows serial guard refuses system COM1 COM3 COM9 and malformed device names" {
    try std.testing.expect(serial_windows.allowedComName("COM13"));
    try std.testing.expect(serial_windows.allowedComName("COM14"));
    try std.testing.expect(!serial_windows.allowedComName("COM0"));
    try std.testing.expect(!serial_windows.allowedComName("COM1"));
    try std.testing.expect(!serial_windows.allowedComName("COM3"));
    try std.testing.expect(!serial_windows.allowedComName("COM9"));
    try std.testing.expect(!serial_windows.allowedComName("\\\\.\\COM13"));
    try std.testing.expect(!serial_windows.allowedComName("LPT1"));
}
