const std = @import("std");
const protocol = @import("ra8").dap.protocol;

test "JSON access rejects wrong types and out-of-range request numbers" {
    try std.testing.expectError(error.InvalidArguments, protocol.number(.{ .integer = -1 }));
    try std.testing.expectError(error.InvalidArguments, protocol.number(.{ .integer = 0x1_0000_0000 }));
    try std.testing.expectError(error.InvalidArguments, protocol.text(.null));
    try std.testing.expectEqual(@as(u32, 1), try protocol.number(.{ .integer = 1 }));
}
