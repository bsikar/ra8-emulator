const std = @import("std");

const emu_list = @import("ra8").host.jlink.emu_list;

test "ShowEmuList parser extracts USB probe serials regardless of driver order" {
    const sample =
        "SEGGER J-Link Commander V8.18\r\n" ++
        "J-Link[0]: Connection: USB, Serial number: 1088957027, ProductName: J-Link-OB-RA4M2\r\n" ++
        "J-Link[1]: Connection: IP, Serial number: 999999999, ProductName: J-Link-Pro\r\n" ++
        "J-Link[2]: Connection: USB, Serial number: 1083322193, ProductName: J-Link-OB-RA4M2\r\n";
    var out: [8]emu_list.Probe = undefined;
    const listed = try emu_list.parse(sample, &out);
    try std.testing.expectEqual(@as(usize, 2), listed.len);
    try std.testing.expectEqual(@as(u64, 1088957027), listed[0].serial);
    try std.testing.expectEqual(@as(u64, 1083322193), listed[1].serial);
    try std.testing.expectEqualStrings("J-Link-OB-RA4M2", listed[0].product);

    var digits: [20]u8 = undefined;
    try std.testing.expectEqualStrings("001083322193", emu_list.format(listed[1].serial, &digits));
    try std.testing.expectEqual(@as(u64, 1083322193), try emu_list.serialOf("001083322193"));
    try std.testing.expectEqual(@as(u64, 1083322193), try emu_list.serialOf("1083322193"));
    try std.testing.expectError(error.BadSerial, emu_list.serialOf("0"));
}

test "duplicate or malformed USB probe serials are rejected" {
    var out: [4]emu_list.Probe = undefined;
    const dup =
        "J-Link[0]: Connection: USB, Serial number: 1083322193, ProductName: J-Link-OB-RA4M2\n" ++
        "J-Link[1]: Connection: USB, Serial number: 1083322193, ProductName: J-Link-OB-RA4M2\n";
    try std.testing.expectError(error.DuplicateSerial, emu_list.parse(dup, &out));
    const zero = "J-Link[0]: Connection: USB, Serial number: 0, ProductName: J-Link\n";
    try std.testing.expectError(error.BadListing, emu_list.parse(zero, &out));
}
