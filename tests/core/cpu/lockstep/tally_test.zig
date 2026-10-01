//! Covers src/core/cpu/lockstep/tally.zig.
const std = @import("std");
const ra8 = @import("ra8");
const tally = ra8.core.cpu.lockstep.tally;

test "each outcome lands in its class's column" {
    const gpa = std.testing.allocator;
    var counts: tally.Tally = .{};
    defer counts.deinit(gpa);
    try counts.record(gpa, "hint", .matched);
    try counts.record(gpa, "hint", .matched);
    try counts.record(gpa, "hint", .diverged);
    try counts.record(gpa, "lob", .skipped);
    const hint = counts.find("hint").?;
    try std.testing.expectEqual(@as(u64, 2), hint.matched);
    try std.testing.expectEqual(@as(u64, 1), hint.diverged);
    try std.testing.expectEqual(@as(u64, 3), hint.total());
    try std.testing.expectEqual(@as(u64, 1), counts.find("lob").?.skipped);
    try std.testing.expectEqual(@as(?tally.Row, null), counts.find("absent"));
}

test "the sum adds every class" {
    const gpa = std.testing.allocator;
    var counts: tally.Tally = .{};
    defer counts.deinit(gpa);
    try counts.record(gpa, "a", .matched);
    try counts.record(gpa, "b", .diverged);
    try counts.record(gpa, "b", .skipped);
    const whole = counts.sum();
    try std.testing.expectEqual(@as(u64, 1), whole.matched);
    try std.testing.expectEqual(@as(u64, 1), whole.diverged);
    try std.testing.expectEqual(@as(u64, 1), whole.skipped);
}

test "the table is Markdown, classes in first-seen order, then a total" {
    const gpa = std.testing.allocator;
    var counts: tally.Tally = .{};
    defer counts.deinit(gpa);
    try counts.record(gpa, "hint", .matched);
    try counts.record(gpa, "lob", .skipped);
    var buffer: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    try counts.writeTable(stream.writer());
    try std.testing.expectEqualStrings(
        \\| class | matched | diverged | skipped |
        \\|---|---:|---:|---:|
        \\| hint | 1 | 0 | 0 |
        \\| lob | 0 | 0 | 1 |
        \\| total | 1 | 0 | 1 |
        \\
    , stream.getWritten());
}

test "an empty tally still prints the header and a zero total" {
    var counts: tally.Tally = .{};
    var buffer: [128]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    try counts.writeTable(stream.writer());
    try std.testing.expect(std.mem.endsWith(u8, stream.getWritten(), "| total | 0 | 0 | 0 |\n"));
}
