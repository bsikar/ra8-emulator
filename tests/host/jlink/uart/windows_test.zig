const std = @import("std");

const windows = @import("ra8").host.jlink.uart_windows;

test "Windows composite USB matcher binds only the parent J-Link serial regardless of PID" {
    try std.testing.expect(windows.matches("USB\\VID_1366&PID_0105\\001083322193", 1083322193));
    try std.testing.expect(windows.matches("USB\\VID_1366&PID_1024\\001083322193", 1083322193));
    try std.testing.expect(!windows.matches("USB\\VID_1366&PID_1024&MI_00\\9&2559DCD&0&0000", 1083322193));
    try std.testing.expect(!windows.matches("USB\\VID_1366&PID_1024\\001088957027", 1083322193));
    try std.testing.expect(!windows.matches("USB\\VID_0403&PID_6001\\001083322193", 1083322193));
}
