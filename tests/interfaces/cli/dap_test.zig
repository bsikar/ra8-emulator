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
