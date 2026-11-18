const std = @import("std");

const Queue = @import("ra8").rpc.target_progress.Queue;

test "target_progress queue preserves monotonic sequence numbers and bounds capacity" {
    var q: Queue = .{};
    for (0..18) |i| {
        var buf: [32]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "{{\"n\":{d}}}", .{i});
        q.push("flash", msg);
    }
    try std.testing.expectEqual(@as(usize, 16), q.count);
    const oldest = q.pop().?;
    try std.testing.expectEqual(@as(u64, 3), oldest.sequence);
    try std.testing.expectEqualStrings("flash", oldest.stage[0..oldest.stage_len]);
    try std.testing.expectEqualStrings("{\"n\":2}", oldest.json[0..oldest.json_len]);
    q.clear();
    try std.testing.expect(q.pop() == null);
}
