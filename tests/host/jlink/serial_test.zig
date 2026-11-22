const builtin = @import("builtin");
const std = @import("std");

const serial = @import("ra8").host.jlink.serial;

test "serial port lookup by non-existent probe serial returns null without opening host ports" {
    if (builtin.os.tag != .windows and builtin.os.tag != .linux and builtin.os.tag != .macos) {
        try std.testing.expectError(error.Unsupported, serial.Port.openBySerial(std.testing.io, 999999999999));
        return;
    }
    const found = try serial.Port.openBySerial(std.testing.io, 999999999999);
    try std.testing.expect(found == null);
}
