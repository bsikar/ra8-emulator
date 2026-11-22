const std = @import("std");

const macos = @import("ra8").host.jlink.uart_macos;

const sample_ioreg =
    \\+-o CDC@0  <class IOUSBHostInterface, id 0x100032f84>
    \\  |   "idVendor" = 4966
    \\  |   "USB Serial Number" = "001083322193"
    \\+-o CDC DATA interface@1  <class IOUSBHostInterface, id 0x100032f87>
    \\  |   "idVendor" = 4966
    \\  |   "USB Serial Number" = "001083322193"
    \\  |   "IOCalloutDevice" = "/dev/cu.usbmodem0010833221931"
    \\+-o CDC DATA interface@1  <class IOUSBHostInterface, id 0x10003311c>
    \\  |   "idVendor" = 4966
    \\  |   "USB Serial Number" = "001088957027"
    \\  |   "IOCalloutDevice" = "/dev/cu.usbmodem0010889570271"
    \\+-o IOUSBHostInterface@1  <class IOUSBHostInterface, id 0x100032be1>
    \\  |   "idVendor" = 6790
    \\  |   "USB Serial Number" = "5B42058357"
    \\  |   "IOCalloutDevice" = "/dev/cu.usbmodem5B420583571"
    \\+-o IOUSBHostInterface@2  <class IOUSBHostInterface, id 0x100032be2>
    \\  |   "idVendor" = 6790
    \\  |   "USB Serial Number" = "001083322193"
    \\  |   "IOCalloutDevice" = "/dev/cu.usbmodem9999999999991"
    \\
;

test "macOS ioreg matcher resolves exact SEGGER CDC callout by serial and skips non-SEGGER vendors" {
    var out: [64]u8 = undefined;
    const e1 = (try macos.parseIoreg(sample_ioreg, 1083322193, &out)).?;
    try std.testing.expectEqualStrings("/dev/cu.usbmodem0010833221931", e1);

    const t1 = (try macos.parseIoreg(sample_ioreg, 1088957027, &out)).?;
    try std.testing.expectEqualStrings("/dev/cu.usbmodem0010889570271", t1);

    try std.testing.expect((try macos.parseIoreg(sample_ioreg, 5842058357, &out)) == null);
    try std.testing.expect((try macos.parseIoreg(sample_ioreg, 999999999999, &out)) == null);
}

test "macOS ioreg matcher rejects unsafe callout names and duplicate matching serials" {
    const bad =
        \\+-o CDC DATA interface@1  <class IOUSBHostInterface>
        \\  |   "idVendor" = 4966
        \\  |   "USB Serial Number" = "001083322193"
        \\  |   "IOCalloutDevice" = "/dev/tty.usbmodem0010833221931"
        \\
    ;
    var out: [64]u8 = undefined;
    try std.testing.expectError(error.BadPortName, macos.parseIoreg(bad, 1083322193, &out));

    const dup =
        \\+-o CDC DATA interface@1  <class IOUSBHostInterface>
        \\  |   "idVendor" = 4966
        \\  |   "USB Serial Number" = "001083322193"
        \\  |   "IOCalloutDevice" = "/dev/cu.usbmodem0010833221931"
        \\+-o CDC DATA interface@3  <class IOUSBHostInterface>
        \\  |   "idVendor" = 4966
        \\  |   "USB Serial Number" = "001083322193"
        \\  |   "IOCalloutDevice" = "/dev/cu.usbmodem0010833221932"
        \\
    ;
    try std.testing.expectError(error.DuplicateSerial, macos.parseIoreg(dup, 1083322193, &out));
}
