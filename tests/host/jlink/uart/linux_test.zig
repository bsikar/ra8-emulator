const std = @import("std");

const linux = @import("ra8").host.jlink.uart_linux;

test "Linux serial-by-id matcher binds only the CDC interface of the exact J-Link serial" {
    try std.testing.expect(linux.matches("usb-SEGGER_J-Link_OB-RA4M2_001083322193-if00", 1083322193));
    try std.testing.expect(!linux.matches("usb-SEGGER_J-Link_OB-RA4M2_001083322193-if02", 1083322193));
    try std.testing.expect(!linux.matches("usb-SEGGER_J-Link_OB-RA4M2_001088957027-if00", 1083322193));
    try std.testing.expect(!linux.matches("usb-FTDI_FT232R_001083322193-if00", 1083322193));
}
