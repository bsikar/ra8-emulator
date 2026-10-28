//! Tests for src/session/history/segment_recover.zig: an empty segment
//! recovers as it is, and a torn tail is truncated away through the storage.
const std = @import("std");
const ra8 = @import("ra8");
const recover = ra8.session.history_segment_recover;
const Storage = ra8.session.history_recorder.Storage;

const Trim = struct {
    cut: ?u64 = null,

    fn append(_: *anyopaque, _: []const u8) anyerror!void {}
    fn flush(_: *anyopaque) anyerror!void {}
    fn truncate(context: *anyopaque, len: u64) anyerror!void {
        const self: *Trim = @ptrCast(@alignCast(context));
        self.cut = len;
    }
    fn storage(self: *Trim) Storage {
        return .{ .context = self, .append = append, .flush = flush, .truncate = truncate };
    }
};

test "an empty segment recovers with no frames and nothing cut" {
    var trim: Trim = .{};
    const got = try recover.recoverSegment(&.{}, trim.storage());
    try std.testing.expectEqual(@as(usize, 0), got.frames);
    try std.testing.expect(!got.torn);
    try std.testing.expect(trim.cut == null);
}

test "a segment that ends partway through a frame is cut back to its whole frames" {
    var trim: Trim = .{};
    const got = try recover.recoverSegment(&.{ 0x01, 0x02, 0x03 }, trim.storage());
    try std.testing.expect(got.torn);
    try std.testing.expectEqual(@as(u64, 0), got.complete_end);
    try std.testing.expectEqual(@as(?u64, 0), trim.cut);
}
