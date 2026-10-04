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
