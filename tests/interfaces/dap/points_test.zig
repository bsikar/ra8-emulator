const std = @import("std");
const fixture = @import("fixture.zig");

test "replacing and disconnecting clears only adapter-owned Session breakpoints" {
    var f: fixture.Fixture = .{};
    try f.init();
    const other = try f.session.setBreakpoint(.cpu0, .{ .address = 10 });
    try fixture.connect(&f.adapter);
    try fixture.expectSend(&f.adapter,
        \\{"seq":4,"type":"request","command":"setInstructionBreakpoints","arguments":{"breakpoints":[{"instructionReference":"0x0c"}]}}
    , "\"verified\":true");
    try std.testing.expectEqual(@as(usize, 2), f.machine.breaks.len);
    try fixture.expectSend(&f.adapter,
        \\{"seq":5,"type":"request","command":"setInstructionBreakpoints","arguments":{"breakpoints":[]}}
    , "\"breakpoints\":[]");
    try std.testing.expectEqual(@as(usize, 1), f.machine.breaks.len);
    try std.testing.expect(try f.session.breakpointExists(.cpu0, other));
    f.deinit();
    try std.testing.expect(try f.session.breakpointExists(.cpu0, other));
}

test "source availability errors are explicit and do not block instruction-only debugging" {
    var f: fixture.Fixture = .{};
    try f.init();
    defer f.deinit();
    var calls: u8 = 0;
    const Source = struct {
        fn path(context: *anyopaque, _: []const u8, _: bool, _: []u8) anyerror![]const u8 {
            const count: *u8 = @ptrCast(@alignCast(context));
            count.* += 1;
            return error.SourceMissing;
        }
    };
    f.adapter.target.?.sources = .{ .context = &calls, .pathFn = Source.path };
    try fixture.connect(&f.adapter);
    try fixture.expectSend(&f.adapter,
        \\{"seq":4,"type":"request","command":"setBreakpoints","arguments":{"source":{"path":"C:/client/main.zig"},"breakpoints":[{"line":1}]}}
    , "SourceMissing");
    try std.testing.expectEqual(@as(u8, 1), calls);
    try fixture.expectSend(&f.adapter,
        \\{"seq":5,"type":"request","command":"setInstructionBreakpoints","arguments":{"breakpoints":[{"instructionReference":"0x0c"}]}}
    , "\"verified\":true");
    try std.testing.expectEqual(@as(u8, 1), calls);
}
