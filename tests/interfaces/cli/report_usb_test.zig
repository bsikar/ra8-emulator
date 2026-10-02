//! Tests for src/interfaces/cli/report_usb.zig.
const std = @import("std");
const ra8 = @import("ra8");

const report_usb = ra8.board.report.usb;
const Host = ra8.periph.usbfs.host.Host;

fn render(host: *const Host) !std.BoundedArray(u8, 512) {
    var text = std.BoundedArray(u8, 512){};
    try report_usb.section(host, text.writer());
    return text;
}

test "nothing while no device is on the jack" {
    const host = Host{};
    const text = try render(&host);
    try std.testing.expectEqual(@as(usize, 0), text.len);
}

test "a stalled step names itself and how long it waited" {
    var host = Host{ .step = .device_descriptor, .waited = 20 };
    const text = try render(&host);
    try std.testing.expectEqualStrings(
        "USBFS host: enumeration device_descriptor after 20 boundary(ies) on that step\n",
        text.constSlice(),
    );
}

test "a configured device prints both descriptors" {
    var host = Host{ .step = .configured };
    host.device[0] = 0x12;
    host.device[1] = 0x01;
    host.config[0] = 0x09;
    host.config[1] = 0x02;
    const text = try render(&host);
    try std.testing.expect(std.mem.startsWith(u8, text.constSlice(), "USBFS host: enumeration configured\n"));
    try std.testing.expect(std.mem.indexOf(u8, text.constSlice(), "device descriptor 12 01 00") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.constSlice(), "config descriptor 09 02 00") != null);
}
