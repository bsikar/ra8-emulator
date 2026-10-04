//! Covers src/interfaces/cli/zig_stop.zig: the `--stop-sym` counter a Zig
//! run watches (RA8EMU-603).
const std = @import("std");
const ra8 = @import("ra8");

const zig_stop = ra8.board.zig_run.stop_sym;
const Builder = @import("../../debug/symbol_image.zig").Builder;

test "a --stop-sym name resolves to its address and floor" {
    var bytes: [4096]u8 align(4) = undefined;
    const image = try ra8.core.elf.Image.init(Builder.build(&bytes, &.{"g_tick"}, &.{0x2200_08D8}));
    const options: ra8.core.cli.Options = .{ .path = "x.elf", .stop_symbol = "g_tick", .stop_at = 3 };
    const watch = zig_stop.resolve(image, options) orelse return error.TestExpectedStop;
    try std.testing.expectEqual(@as(u32, 0x2200_08D8), watch.address);
    try std.testing.expectEqual(@as(u32, 3), watch.reaches);
}

test "no --stop-sym means nothing is watched" {
    var bytes: [4096]u8 align(4) = undefined;
    const image = try ra8.core.elf.Image.init(Builder.build(&bytes, &.{"g_tick"}, &.{0x2200_08D8}));
    try std.testing.expect(zig_stop.resolve(image, .{ .path = "x.elf" }) == null);
}

test "--ms gives a window in SysTick periods" {
    const due = zig_stop.deadline(.{ .path = "x.elf", .ms = 4000 }) orelse return error.TestExpectedDeadline;
    try std.testing.expectEqual(@as(u64, 4000), due.periods);
    try std.testing.expect(zig_stop.deadline(.{ .path = "x.elf" }) == null);
}

test "the verdict says which of counter, deadline and budget ended the run" {
    var buffer: [128]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    const options: ra8.core.cli.Options = .{ .path = "x.elf", .stop_symbol = "g_tick", .stop_at = 3 };
    const spent: ra8.core.deadline.Deadline = .{ .periods = 50, .reached = true };
    try zig_stop.verdict(stream.writer(), .{ .path = "x.elf" }, null, spent, 0x10, 99);
    try std.testing.expectEqualStrings("stopped clean after 50 ms, pc 0x00000010\n", stream.getWritten());
    stream.reset();
    try zig_stop.verdict(stream.writer(), options, .{ .address = 0x2200_0000, .reaches = 3 }, spent, 0x10, 99);
    try std.testing.expectEqualStrings("ran 50 ms, g_tick never reached 3, pc 0x00000010\n", stream.getWritten());
    stream.reset();
    try zig_stop.verdict(stream.writer(), options, .{ .address = 0x2200_0000, .reaches = 3 }, null, 0x10, 99);
    try std.testing.expectEqualStrings("ran 99 instructions, g_tick never reached 3, pc 0x00000010\n", stream.getWritten());
    stream.reset();
    try zig_stop.verdict(stream.writer(), .{ .path = "x.elf" }, null, null, 0x10, 99);
    try std.testing.expectEqualStrings("", stream.getWritten());
}
