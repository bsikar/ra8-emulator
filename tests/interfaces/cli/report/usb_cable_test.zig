//! Tests for src/interfaces/cli/report/usb_cable.zig.
const std = @import("std");
const ra8 = @import("ra8");

const usb_cable = ra8.board.report.usb_cable;
const usbfs = ra8.periph.usbfs;
const Host = ra8.periph.usbhs.Host;
const Loop = ra8.periph.usbhs.loop.Loop;

fn render(host: *const Host) !std.BoundedArray(u8, 512) {
    var text = std.BoundedArray(u8, 512){};
    try usb_cable.section(host, text.writer());
    return text;
}

test "nothing while no cable is in" {
    const host = Host{};
    const text = try render(&host);
    try std.testing.expectEqual(@as(usize, 0), text.len);
}

test "a cable names the device's state and what crossed it" {
    var device = usbfs.Device{};
    var cable = Loop{ .device = &device, .setups = 3, .ins = 2, .bulk_outs = 1 };
    var host = Host{};
    host.xfer.loop = &cable;
    const text = try render(&host);
    try std.testing.expectEqualStrings(
        "  cabled to the board's FS device, which is powered: 3 SETUP(s), " ++
            "2 control IN, 0 control OUT, 1 bulk OUT, 0 bulk IN\n",
        text.constSlice(),
    );
}

test "bulk tokens with no pipe open get their own line" {
    var device = usbfs.Device{};
    var cable = Loop{ .device = &device, .unopened = 4 };
    var host = Host{};
    host.xfer.loop = &cable;
    const text = try render(&host);
    try std.testing.expect(std.mem.indexOf(u8, text.constSlice(), "4 bulk token(s) for an endpoint") != null);
}

test "DVSQ names" {
    try std.testing.expectEqualStrings("configured", usb_cable.stateName(usbfs.intsts0.dvsq_configured));
    try std.testing.expectEqualStrings("addressed", usb_cable.stateName(usbfs.intsts0.dvsq_address));
    try std.testing.expectEqualStrings("suspended", usb_cable.stateName(0x0040));
}
