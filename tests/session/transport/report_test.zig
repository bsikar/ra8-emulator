//! Tests for src/session/transport/report.zig: an idle transport reports
//! itself halted, with no job state, at the machine's position.
const std = @import("std");
const rig = @import("../history/window_rig.zig");

test "an idle transport reports halted with no state at the machine's position" {
    var opened = try rig.openCounting(std.testing.allocator, null);
    defer opened.deinit();
    const report = opened.transport().report();
    try std.testing.expectEqual(.halted, report.phase);
    try std.testing.expect(report.state == null);
    try std.testing.expect(std.meta.eql(report.position.?, opened.session().grid.?.at));
    try std.testing.expectEqual(@as(u64, 0), report.progress.slices);
}
