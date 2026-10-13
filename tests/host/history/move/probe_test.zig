const std = @import("std");
const h = @import("ra8").host.history;
const f = @import("../root_test.zig");
test "host move observation propagates an injected interruption to its caller" {
    var fixture = try f.Fixture.init();
    defer fixture.deinit();
    var observed = false;
    const callback = struct {
        fn reached(context: *anyopaque, phase: h.move.probe.Phase, _: std.Io.Dir, _: []const u8, _: std.Io.Dir, _: []const u8) !void {
            const seen: *bool = @ptrCast(@alignCast(context));
            seen.* = phase == .file_linked;
            return error.OwnedInterruption;
        }
    };
    try std.testing.expectError(error.OwnedInterruption, h.move.probe.reach(.{ .context = &observed, .reached = callback.reached }, .file_linked, fixture.cache.dir, "source", fixture.kept.dir, "target"));
    try std.testing.expect(observed);
}
