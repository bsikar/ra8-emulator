const std = @import("std");
const relocation = @import("cli_app").host.relocation;

test "CLI peer capability refuses a relative executable before root creation" {
    try std.testing.expectError(error.RelativePath, relocation.capability(std.testing.io, "peer.exe"));
}
