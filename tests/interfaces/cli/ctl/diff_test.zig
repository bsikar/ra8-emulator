//! Tests for ctl diff command (Slice 23.5).
const std = @import("std");
const cli_app = @import("cli_app");
const session_ctl = cli_app.session_ctl;

test "session_ctl parses diff command" {
    const allocator = std.testing.allocator;

    const req = try session_ctl.parse(allocator, &.{
        "ra8_emulator",
        "ctl",
        "--connect",
        "tcp:127.0.0.1:9000",
        "diff",
        "chk:1",
        "chk:2",
    });
    switch (req.command) {
        .diff_cmd => |cmd| {
            try std.testing.expectEqualStrings("chk:1", cmd.a);
            try std.testing.expectEqualStrings("chk:2", cmd.b);
        },
        else => unreachable,
    }
}

test "session_ctl diff command rejects bad arguments" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.BadArguments, session_ctl.parse(allocator, &.{
        "ra8_emulator",
        "ctl",
        "--connect",
        "tcp:127.0.0.1:9000",
        "diff",
        "only_one",
    }));

    try std.testing.expectError(error.BadArguments, session_ctl.parse(allocator, &.{
        "ra8_emulator",
        "ctl",
        "--connect",
        "tcp:127.0.0.1:9000",
        "diff",
        "a",
        "b",
        "c",
    }));
}
