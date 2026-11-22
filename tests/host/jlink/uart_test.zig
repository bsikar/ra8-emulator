const builtin = @import("builtin");
const std = @import("std");

const uart = @import("ra8").host.jlink.uart;

test "UART lookup reports unsupported on unimplemented platforms and null for absent serials" {
    var out: [64]u8 = undefined;
    if (builtin.os.tag != .windows and builtin.os.tag != .linux and builtin.os.tag != .macos) {
        try std.testing.expectError(error.Unsupported, uart.find(std.testing.io, 999999999999, &out));
        return;
    }
    const found = try uart.find(std.testing.io, 999999999999, &out);
    try std.testing.expect(found == null);
}
