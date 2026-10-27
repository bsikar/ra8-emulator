//! The core-only stream is, byte for byte, the run of core sections inside
//! the side save, so a reverse window can splice one into the other.
const std = @import("std");
const ra8 = @import("ra8");
const rig = @import("../history/window_rig.zig");

const delta = ra8.session.history_window_delta;

test "the core stream equals the core span of the side save, and the span is found" {
    var opened = try rig.openCounting(std.testing.allocator, null);
    defer opened.deinit();
    const files = &opened.state.files;
    var side: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer side.deinit();
    try files.writeParts(&side.writer, .{ .memory = false });
    var core: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer core.deinit();
    try ra8.session.board.core_stream.write(files, files.identity(), &core.writer);

    const span = (try delta.coreSpan(side.written())).?;
    try std.testing.expectEqualSlices(u8, side.written()[span.lo..span.hi], core.written());
    // Run a while: the core sections move, the span keeps its size.
    try rig.runCount(&opened, 40);
    var after: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer after.deinit();
    try ra8.session.board.core_stream.write(files, files.identity(), &after.writer);
    try std.testing.expectEqual(core.written().len, after.written().len);
    try std.testing.expect(!std.mem.eql(u8, core.written(), after.written()));
}

test "a span delta carries image offsets and turns the span's image into the next" {
    const gpa = std.testing.allocator;
    const pre = [_]u8{ 9, 9, 1, 2, 3, 4, 5, 6, 7, 9 };
    const post = [_]u8{ 1, 2, 3, 9, 3, 4, 5, 8, 7 };
    var d = try delta.encodeRuns(gpa, pre[2..9], post[2..9], 2);
    defer d.deinit(gpa);
    try std.testing.expect(!d.board);
    var image: std.ArrayList(u8) = .empty;
    defer image.deinit(gpa);
    try image.appendSlice(gpa, &pre);
    try d.flip(gpa, &image, true);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 9, 9, 3, 9, 3, 4, 5, 8, 7, 9 }, image.items);
    try d.flip(gpa, &image, false);
    try std.testing.expectEqualSlices(u8, &pre, image.items);
}
