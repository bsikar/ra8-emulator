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
