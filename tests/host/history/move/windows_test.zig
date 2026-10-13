const std = @import("std");
const builtin = @import("builtin");
const peer = @import("ra8").host.history.move.windows.peer;

test "native peer refuses a non-Windows process without consuming input" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try std.testing.expectError(error.OperationUnsupported, peer(std.testing.allocator, std.testing.io));
}
