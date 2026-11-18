//! The real launch owner must detach history capture before stepping.
const std = @import("std");
const cli = @import("cli_app");
const ra8 = @import("ra8");
const fixture = @import("../dap/fixture.zig");

test "DAP launch owner steps a real loaded harness without a history ring" {
    var owner: cli.dap.Owner = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer if (owner.harness) |*h| h.deinit();
    const target = try cli.dap.Owner.open(&owner, @import("test_paths").call_tree);
    try std.testing.expect(target.session.history == null);
    var adapter: ra8.dap.adapter.Adapter = .{ .allocator = std.testing.allocator, .target = target };
    defer adapter.deinit();
    try fixture.connect(&adapter);
    try fixture.expectSend(&adapter,
        \\{"seq":4,"type":"request","command":"stepIn","arguments":{"threadId":1,"granularity":"instruction"}}
    , "\"success\":true");
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try adapter.pump(&out.writer);
    try std.testing.expect(adapter.pending == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"reason\":\"step\"") != null);
}

test "DAP command line takes --part only after the subcommand and only with a value" {
    const machines = &ra8.chip.core.machine.catalog.all;
    const plain = cli.dap.parseArgs(&.{ "emu", "dap", "4711" }, machines).?;
    try std.testing.expectEqual(@as(u16, 4711), plain.port);
    try std.testing.expectEqual(&ra8.chip.core.machine.catalog.ra8p1, plain.machine);
    try std.testing.expectEqual(@as(?[]const u8, null), plain.image);
    const picked = cli.dap.parseArgs(&.{ "emu", "dap", "--part", "ra8d2", "4711", "fw.elf" }, machines).?;
    try std.testing.expectEqual(&ra8.chip.core.machine.catalog.ra8d2, picked.machine);
    try std.testing.expectEqualStrings("fw.elf", picked.image.?);
    const after = cli.dap.parseArgs(&.{ "emu", "dap", "4711", "--device", "ra8d2" }, machines).?;
    try std.testing.expectEqual(&ra8.chip.core.machine.catalog.ra8d2, after.machine);
    try std.testing.expectEqual(@as(?[]const u8, null), after.image);
    try std.testing.expect(cli.dap.parseArgs(&.{ "emu", "dap", "4711", "--part" }, machines) == null);
    try std.testing.expect(cli.dap.parseArgs(&.{ "emu", "dap", "4711", "--part", "nope" }, machines) == null);
    try std.testing.expect(cli.dap.parseArgs(&.{ "emu", "--part", "ra8d2", "4711" }, machines) == null);
    try std.testing.expect(cli.dap.parseArgs(&.{ "emu", "dap", "4711", "a.elf", "b.elf" }, machines) == null);
    try std.testing.expect(cli.dap.parseArgs(&.{ "emu", "dap", "port" }, machines) == null);
}
