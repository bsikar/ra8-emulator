//! Tests for ctl write command parsing and structures.
const std = @import("std");
const write_mod = @import("cli_app").ctl_write;

test "parseReg parses valid register and value" {
    const args = [_][]const u8{ "r0", "0x12345678" };
    const cmd = try write_mod.parseReg(&args);
    switch (cmd) {
        .write_reg => |r| {
            try std.testing.expectEqualStrings("r0", @tagName(r.reg));
            try std.testing.expectEqual(@as(u32, 0x12345678), r.value);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseReg refuses bad argument count and bad register" {
    const args1 = [_][]const u8{"r0"};
    try std.testing.expectError(error.BadArguments, write_mod.parseReg(&args1));

    const args2 = [_][]const u8{ "not_a_reg", "100" };
    try std.testing.expectError(error.UnknownRegister, write_mod.parseReg(&args2));
}

test "parseMem parses valid hex string" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "0x20000000", "01020304" };
    const cmd = try write_mod.parseMem(allocator, &args);
    switch (cmd) {
        .write_mem => |m| {
            defer allocator.free(m.bytes);
            try std.testing.expectEqual(@as(u32, 0x20000000), m.addr);
            try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4 }, m.bytes);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseWord parses set NAME=VALUE with optional --frame and rejects invalid syntax" {
    const allocator = std.testing.allocator;
    const direct = (try write_mod.parseWord(allocator, "set", &.{"g_count=42"})).?;
    try std.testing.expectEqual(@as(u32, 0), direct.set_var.frame);
    try std.testing.expectEqualStrings("g_count", direct.set_var.name);
    try std.testing.expectEqualStrings("42", direct.set_var.value);

    const framed = (try write_mod.parseWord(allocator, "set", &.{ "--frame", "2", "local_x=-1" })).?;
    try std.testing.expectEqual(@as(u32, 2), framed.set_var.frame);
    try std.testing.expectEqualStrings("local_x", framed.set_var.name);
    try std.testing.expectEqualStrings("-1", framed.set_var.value);

    try std.testing.expectError(error.BadArguments, write_mod.parseWord(allocator, "set", &.{}));
    try std.testing.expectError(error.BadArguments, write_mod.parseWord(allocator, "set", &.{"no_equals"}));
    try std.testing.expectError(error.BadArguments, write_mod.parseWord(allocator, "set", &.{"=42"}));
    try std.testing.expectError(error.BadArguments, write_mod.parseWord(allocator, "set", &.{"g_count="}));
    try std.testing.expectError(error.BadArguments, write_mod.parseWord(allocator, "set", &.{ "a=1", "b=2" }));
    try std.testing.expectError(error.BadArguments, write_mod.parseWord(allocator, "set", &.{ "--frame", "xyz", "a=1" }));
}
