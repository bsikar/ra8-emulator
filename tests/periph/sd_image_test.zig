//! Covers src/periph/sd_image.zig.
const std = @import("std");
const image = @import("ra8").periph.sd_image;

fn unit() image.Image {
    return image.Image.init(std.testing.allocator);
}

test "a fresh card holds nothing and reads back zeros" {
    var img = unit();
    defer img.deinit();
    var block: image.Block = undefined;
    try std.testing.expect(img.read(7, &block));
    try std.testing.expectEqual(@as(usize, 0), img.held());
    for (block) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "a written block comes back and is held" {
    var img = unit();
    defer img.deinit();
    var out: image.Block = .{0xA5} ** image.geometry.block_bytes;
    try std.testing.expect(img.write(3, &out));
    try std.testing.expectEqual(@as(usize, 1), img.held());
    var back: image.Block = undefined;
    try std.testing.expect(img.read(3, &back));
    try std.testing.expectEqualSlices(u8, &out, &back);
}

test "a block past the end of the card is not a block" {
    var img = unit();
    defer img.deinit();
    const past = image.geometry.default_capacity_blocks;
    var block: image.Block = .{1} ** image.geometry.block_bytes;
    try std.testing.expect(!img.write(past, &block));
    try std.testing.expect(!img.read(past, &block));
    try std.testing.expect(img.inRange(past - 1));
}

test "an erase gives the blocks back instead of filling them with zeros" {
    var img = unit();
    defer img.deinit();
    const filled: image.Block = .{0xFF} ** image.geometry.block_bytes;
    try std.testing.expect(img.write(10, &filled));
    try std.testing.expect(img.write(11, &filled));
    try std.testing.expect(img.write(20, &filled));
    try std.testing.expectEqual(@as(u32, 2), img.zero(10, 11));
    try std.testing.expectEqual(@as(usize, 1), img.held());
    var back: image.Block = undefined;
    try std.testing.expect(img.read(10, &back));
    for (back) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "an erase of blocks nobody wrote clears nothing" {
    var img = unit();
    defer img.deinit();
    try std.testing.expectEqual(@as(u32, 0), img.zero(0, 31));
}

test "a blank card takes another size, and a card holding data does not" {
    var img = unit();
    defer img.deinit();
    try std.testing.expect(img.resize(128 * 1024));
    try std.testing.expectEqual(@as(u32, 128 * 1024), img.capacity_blocks);
    try std.testing.expect(img.inRange(100 * 1024));
    try std.testing.expectEqual(@as(u32, 127), img.csize());

    try std.testing.expect(!img.resize(0));
    try std.testing.expect(!img.resize(1500));

    const block: image.Block = .{7} ** image.geometry.block_bytes;
    try std.testing.expect(img.write(1, &block));
    try std.testing.expect(!img.resize(64 * 1024));
    try std.testing.expectEqual(@as(u32, 128 * 1024), img.capacity_blocks);
}

test "the CSD capacity field matches the card's own size" {
    var blank = unit();
    defer blank.deinit();
    try std.testing.expectEqual(
        image.geometry.default_capacity_blocks / image.geometry.csize_unit - 1,
        blank.csize(),
    );
}

test "a rewrite replaces the block instead of holding a second one" {
    var img = unit();
    defer img.deinit();
    const first: image.Block = .{1} ** image.geometry.block_bytes;
    const second: image.Block = .{2} ** image.geometry.block_bytes;
    try std.testing.expect(img.write(5, &first));
    try std.testing.expect(img.write(5, &second));
    try std.testing.expectEqual(@as(usize, 1), img.held());
    var back: image.Block = undefined;
    try std.testing.expect(img.read(5, &back));
    try std.testing.expectEqual(@as(u8, 2), back[0]);
}

test "release hands every block back" {
    var img = unit();
    defer img.deinit();
    const filled: image.Block = .{9} ** image.geometry.block_bytes;
    try std.testing.expect(img.write(1, &filled));
    img.release();
    try std.testing.expectEqual(@as(usize, 0), img.held());
}
