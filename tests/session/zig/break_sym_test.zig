//! Covers src/session/zig/break_sym.zig: the `--break-sym` arrival a Zig
//! run counts and the verdict it prints (RA8EMU-603), and the `--count-pc`
//! addresses the same retire hook counts (RA8EMU-951).
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");

const zig_break = cli_app.zig.run.break_sym;
const Builder = @import("../symbol_image.zig").Builder;

test "a --break-sym name resolves to its address and arrival" {
    var bytes: [4096]u8 align(4) = undefined;
    const image = try ra8.board.image.elf.Image.init(Builder.build(&bytes, &.{"blink_tick"}, &.{0x0200_9071}));
    const point = zig_break.resolve(image, "blink_tick", 2) orelse return error.TestExpectedBreak;
    try std.testing.expectEqual(@as(u64, 0x0200_9070), point.watchedAddress());
    try std.testing.expectEqual(@as(u32, 2), point.arrival);
}

test "no --break-sym means no break" {
    var bytes: [4096]u8 align(4) = undefined;
    const image = try ra8.board.image.elf.Image.init(Builder.build(&bytes, &.{"blink_tick"}, &.{0x0200_9071}));
    try std.testing.expect(zig_break.resolve(image, null, 1) == null);
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

test "a --count-pc address alone turns the listener on and counts each retire of it" {
    var hits: ra8.session.pc_hits.Hits = .{};
    hits.want(0x0200_9070);
    hits.want(0x0200_9080);
    var retire: zig_break.Retire = .{ .hits = &hits };
    const listener = retire.listener() orelse return error.TestExpectedListener;
    // The third carries the Thumb bit, which names the same instruction.
    for ([_]u32{ 0x0200_9070, 0x0200_9072, 0x0200_9071, 0x0200_9070 }) |address| listener.instruction(address);
    try std.testing.expectEqual(@as(u64, 3), hits.asked()[0].hits);
    try std.testing.expectEqual(@as(u64, 0), hits.asked()[1].hits);
}

test "a --count-pc address keeps counting past a break that was met" {
    var hits: ra8.session.pc_hits.Hits = .{};
    hits.want(0x0200_9070);
    var point: zig_break.Break = .{ .address = 0x0200_9071, .arrival = 1 };
    var retire: zig_break.Retire = .{ .point = &point, .hits = &hits };
    for ([_]u32{ 0x0200_9070, 0x0200_9070 }) |address| retire.instruction(address);
    try std.testing.expect(point.reached);
    try std.testing.expectEqual(@as(u64, 2), hits.asked()[0].hits);
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
