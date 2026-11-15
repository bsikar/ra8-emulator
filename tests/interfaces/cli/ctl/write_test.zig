//! Tests for ctl write command parsing and structures.
const std = @import("std");
const write_mod = @import("cli_app").ctl_write;
const serve_peer = @import("../serve_peer.zig");
const ctl_run = @import("../ctl_run.zig");

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

test "undo and reset-image reject arguments" {
    for ([_][]const u8{ "undo", "reset-image" }) |name| {
        const cmd = (try write_mod.parseWord(std.testing.allocator, name, &.{})).?;
        try std.testing.expect(cmd == .undo or cmd == .reset_image);
        try std.testing.expectError(error.BadArguments, write_mod.parseWord(std.testing.allocator, name, &.{"extra"}));
    }
}

test "ctl restores debugger writes and the clean image over TCP" {
    const gpa = std.testing.allocator;
    var line: [256]u8 = undefined;
    var served = try serve_peer.listen("tcp:127.0.0.1:0", &line);
    defer served.child.kill(std.testing.io);
    var initial = try ctl_run.run(gpa, served.bound, &.{ "regs", "r0", "pc" });
    defer initial.deinit();
    const before = initial.field("registers").object;
    const r0 = try ctl_run.expectInteger(before.get("r0").?);
    const pc = try ctl_run.expectInteger(before.get("pc").?);
    var written = try ctl_run.run(gpa, served.bound, &.{ "write-reg", "r0", "0x12345678" });
    defer written.deinit();
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, written.term);
    var undone = try ctl_run.run(gpa, served.bound, &.{"undo"});
    defer undone.deinit();
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, undone.term);
    try std.testing.expect(undone.field("undo").bool);
    var restored = try ctl_run.run(gpa, served.bound, &.{ "regs", "r0" });
    defer restored.deinit();
    try std.testing.expectEqual(r0, try ctl_run.expectInteger(restored.field("registers").object.get("r0").?));
    var edited = try ctl_run.run(gpa, served.bound, &.{ "write-reg", "pc", "0x02000010" });
    defer edited.deinit();
    var reset = try ctl_run.run(gpa, served.bound, &.{"reset-image"});
    defer reset.deinit();
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, reset.term);
    try std.testing.expect(reset.field("reset_image").bool);
    var clean = try ctl_run.run(gpa, served.bound, &.{ "regs", "pc" });
    defer clean.deinit();
    try std.testing.expectEqual(pc, try ctl_run.expectInteger(clean.field("registers").object.get("pc").?));
    var empty = try ctl_run.run(gpa, served.bound, &.{"undo"});
    defer empty.deinit();
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, empty.term);
}

test "variable writes by name share undo and clean reset checkpoints" {
    const gpa = std.testing.allocator;
    var line: [256]u8 = undefined;
    var served = try serve_peer.listen("tcp:127.0.0.1:0", &line);
    defer served.child.kill(std.testing.io);
    var loaded = try ctl_run.run(gpa, served.bound, &.{ "load", ctl_run.uart_image });
    defer loaded.deinit();
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, loaded.term);
    var initial = try ctl_run.run(gpa, served.bound, &.{ "mem", "0x22000034", "4" });
    defer initial.deinit();
    for ([_][]const u8{ "undo", "reset-image" }) |operation| {
        var edited = try ctl_run.run(gpa, served.bound, &.{ "set", "g_uart_irq_echoes=0x12345678" });
        defer edited.deinit();
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, edited.term);
        var restored = try ctl_run.run(gpa, served.bound, &.{operation});
        defer restored.deinit();
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, restored.term);
        var memory = try ctl_run.run(gpa, served.bound, &.{ "mem", "0x22000034", "4" });
        defer memory.deinit();
        try std.testing.expectEqualStrings(initial.field("hex").string, memory.field("hex").string);
    }
}
