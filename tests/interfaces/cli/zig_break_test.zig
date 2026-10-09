//! Covers src/interfaces/cli/zig_break.zig: the `--break-sym` arrival a Zig
//! run counts and the verdict it prints (RA8EMU-603).
const std = @import("std");
const ra8 = @import("ra8");

const zig_break = ra8.board.zig_run.break_sym;
const Builder = @import("../../session/symbol_image.zig").Builder;

test "a --break-sym name resolves to its address and arrival" {
    var bytes: [4096]u8 align(4) = undefined;
    const image = try ra8.board.elf.Image.init(Builder.build(&bytes, &.{"blink_tick"}, &.{0x0200_9071}));
    const options: ra8.core.cli.Options = .{ .path = "x.elf", .break_place = "blink_tick", .break_arrival = 2 };
    const point = zig_break.resolve(image, options) orelse return error.TestExpectedBreak;
    try std.testing.expectEqual(@as(u64, 0x0200_9070), point.watchedAddress());
    try std.testing.expectEqual(@as(u32, 2), point.arrival);
}

test "no --break-sym means no break" {
    var bytes: [4096]u8 align(4) = undefined;
    const image = try ra8.board.elf.Image.init(Builder.build(&bytes, &.{"blink_tick"}, &.{0x0200_9071}));
    try std.testing.expect(zig_break.resolve(image, .{ .path = "x.elf" }) == null);
}

test "arrivals stop counting at the wanted one and keep its address" {
    var point: zig_break.Break = .{ .address = 0x0200_9071, .arrival = 2 };
    var retire: zig_break.Retire = .{ .point = &point };
    try std.testing.expect(retire.listener() != null);
    for ([_]u32{ 0x0200_9070, 0x0200_9072, 0x0200_9070, 0x0200_9070 }) |address| retire.instruction(address);
    try std.testing.expect(point.reached);
    try std.testing.expectEqual(@as(u32, 2), point.seen);
    try std.testing.expectEqual(@as(u32, 0x0200_9070), retire.at);
}

test "nothing to listen for gives no listener" {
    var retire: zig_break.Retire = .{};
    try std.testing.expect(retire.listener() == null);
}

test "the verdict names the arrival and the pc" {
    var buffer: [128]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buffer);
    const met: zig_break.Break = .{ .address = 0x100, .arrival = 1, .seen = 1, .reached = true };
    try zig_break.verdict(&stream, "f", met, 0x100, 0x200, 10);
    try std.testing.expectEqualStrings("reached f arrival 1, pc 0x00000100\n", stream.buffered());
    stream.end = 0;
    const short: zig_break.Break = .{ .address = 0x100, .arrival = 3, .seen = 1 };
    try zig_break.verdict(&stream, "f", short, 0, 0x200, 10);
    try std.testing.expectEqualStrings("ran 10 instructions, reached f 1 time(s) of 3, pc 0x00000200\n", stream.buffered());
}
