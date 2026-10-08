//! Round-trip and deterministic output checks for the pure Zig GIF89a writer.
const std = @import("std");
const ra8 = @import("ra8");
const gif = ra8.board.report.gif;
const lzw_decode = @import("gif_lzw_decode.zig");

const Decoded = struct {
    pixels: []u8,
    delay: u16,
};

fn decodeFrame(bytes: []const u8, allocator: std.mem.Allocator, requested: usize) !Decoded {
    try std.testing.expectEqualStrings("GIF89a", bytes[0..6]);
    var cursor: usize = 13 + 256 * 3 + 19;
    var frame: usize = 0;
    while (cursor < bytes.len and bytes[cursor] != 0x3B) {
        try std.testing.expectEqual(@as(u8, 0x21), bytes[cursor]);
        try std.testing.expectEqual(@as(u8, 0xF9), bytes[cursor + 1]);
        const delay = std.mem.readInt(u16, bytes[cursor + 4 ..][0..2], .little);
        cursor += 8;
        try std.testing.expectEqual(@as(u8, 0x2C), bytes[cursor]);
        cursor += 10;
        try std.testing.expectEqual(@as(u8, 8), bytes[cursor]);
        cursor += 1;

        var compressed: std.ArrayList(u8) = .empty;
        defer compressed.deinit(allocator);
        while (bytes[cursor] != 0) {
            const count = bytes[cursor];
            cursor += 1;
            try compressed.appendSlice(allocator, bytes[cursor .. cursor + count]);
            cursor += count;
        }
        cursor += 1;

        const decoded = try lzw_decode.decode(allocator, compressed.items);
        if (frame == requested) return .{ .pixels = decoded, .delay = delay };
        allocator.free(decoded);
        frame += 1;
    }
    return error.NoFrame;
}

test "GIF sequence round-trips both frames with emulated delay and deterministic bytes" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path_a = try std.fs.path.join(std.testing.allocator, &.{ root, "a.gif" });
    defer std.testing.allocator.free(path_a);
    const path_b = try std.fs.path.join(std.testing.allocator, &.{ root, "b.gif" });
    defer std.testing.allocator.free(path_b);
    const first = [_]u32{ 0xFF11_2233, 0xFFAA_BBCC };
    const second = [_]u32{ 0xFFFF_0000, 0xFF00_FFFF };
    var writer = try gif.Writer.init(std.testing.allocator, std.testing.io, path_a, 2, 1);
    try writer.record(2, 1, &first, 1_000_000);
    try writer.record(2, 1, &second, 31_000_000);
    try writer.finish();
    writer.deinit();
    var again = try gif.Writer.init(std.testing.allocator, std.testing.io, path_b, 2, 1);
    try again.record(2, 1, &first, 1_000_000);
    try again.record(2, 1, &second, 31_000_000);
    try again.finish();
    again.deinit();

    const a = try temp.dir.readFileAlloc(std.testing.io, "a.gif", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(a);
    const b = try temp.dir.readFileAlloc(std.testing.io, "b.gif", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualSlices(u8, a, b);
    const first_frame = try decodeFrame(a, std.testing.allocator, 0);
    defer std.testing.allocator.free(first_frame.pixels);
    const second_frame = try decodeFrame(a, std.testing.allocator, 1);
    defer std.testing.allocator.free(second_frame.pixels);
    try std.testing.expectEqualSlices(u8, &.{ 0x04, 0xB7 }, first_frame.pixels);
    try std.testing.expectEqualSlices(u8, &.{ 0xE0, 0x1F }, second_frame.pixels);
    try std.testing.expectEqual(@as(u16, 3), first_frame.delay);
    try std.testing.expectEqual(@as(u16, 3), second_frame.delay);
    try std.testing.expectError(error.NoFrame, decodeFrame(a, std.testing.allocator, 2));
}
