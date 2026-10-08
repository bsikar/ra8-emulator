//! Covers src/snapshot/units.zig.
const std = @import("std");
const ra8 = @import("ra8");
const file = ra8.snapshot.file;
const units = ra8.snapshot.units;

const Counter = struct { value: u32 = 0, running: bool = false };
const Window = struct { reg: [4]u8 = @splat(0), last: ?u16 = null };

fn saved(list: *std.Io.Writer.Allocating, a: *const Counter, b: *const Window) !void {
    try file.writeHeader(&list.writer);
    try units.save(&list.writer, .timers, .{ a, b });
}

test "units save and load back in order" {
    const a: Counter = .{ .value = 77, .running = true };
    const b: Window = .{ .reg = .{ 1, 2, 3, 4 }, .last = 9 };
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try saved(&list, &a, &b);
    var a2: Counter = .{};
    var b2: Window = .{};
    try units.load(list.written(), .timers, .{ &a2, &b2 });
    try std.testing.expectEqualDeep(a, a2);
    try std.testing.expectEqualDeep(b, b2);
}

test "a missing section or a cut payload leaves every unit untouched" {
    const a: Counter = .{ .value = 77, .running = true };
    const b: Window = .{ .reg = .{ 1, 2, 3, 4 }, .last = 9 };
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try saved(&list, &a, &b);
    var a2: Counter = .{ .value = 5 };
    var b2: Window = .{};
    try std.testing.expectError(error.Missing, units.load(list.written(), .time, .{ &a2, &b2 }));
    // Shrink the section by one byte: the first unit reads, the second fails.
    const len_at = file.magic.len + 4 + 4;
    const len = std.mem.readInt(u64, list.written()[len_at..][0..8], .little);
    std.mem.writeInt(u64, list.written()[len_at..][0..8], len - 1, .little);
    try std.testing.expectError(error.Truncated, units.load(list.written()[0 .. list.written().len - 1], .timers, .{ &a2, &b2 }));
    try std.testing.expectEqual(@as(u32, 5), a2.value);
    try std.testing.expectEqual(@as(?u16, null), b2.last);
}
