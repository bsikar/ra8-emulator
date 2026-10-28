//! Tests for state diff wire codec (Slice 23.5).
const std = @import("std");
const ra8 = @import("ra8");
const diff_wire = ra8.rpc.session.rpc.diff_wire;

test "diff wire round-trip encoding and decoding" {
    var buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    const regs = [_]diff_wire.RegItem{
        .{ .core = 0, .name = "r0", .val_a = 0x1111, .val_b = 0x2222 },
        .{ .core = 1, .name = "pc", .val_a = 0x08000100, .val_b = 0x08000104 },
    };

    const obj_a: [16]u8 = @splat(0xAA);
    const obj_b: [16]u8 = @splat(0xBB);
    const pages = [_]diff_wire.PageItem{
        .{ .space = 2, .page_index = 5, .address = 0x22005000, .has_a = 1, .obj_a = obj_a, .has_b = 1, .obj_b = obj_b },
    };

    const periphs = [_]diff_wire.PeriphItem{
        .{ .unit = "timers", .offset = 0x10, .old_val = 0x100, .new_val = 0x200, .changed_bytes = 4 },
    };

    try diff_wire.encode(&writer, &regs, &pages, &periphs);
    const encoded = writer.buffered();

    var decoded = try diff_wire.decode(std.testing.allocator, encoded);
    defer decoded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), decoded.regs.len);
    try std.testing.expectEqual(@as(u8, 0), decoded.regs[0].core);
    try std.testing.expectEqualStrings("r0", decoded.regs[0].name);
    try std.testing.expectEqual(@as(u32, 0x1111), decoded.regs[0].val_a);
    try std.testing.expectEqual(@as(u32, 0x2222), decoded.regs[0].val_b);

    try std.testing.expectEqual(@as(usize, 1), decoded.pages.len);
    try std.testing.expectEqual(@as(u8, 2), decoded.pages[0].space);
    try std.testing.expectEqual(@as(u32, 5), decoded.pages[0].page_index);
    try std.testing.expectEqual(@as(u32, 0x22005000), decoded.pages[0].address);

    try std.testing.expectEqual(@as(usize, 1), decoded.periphs.len);
    try std.testing.expectEqualStrings("timers", decoded.periphs[0].unit);
    try std.testing.expectEqual(@as(u32, 0x10), decoded.periphs[0].offset);
    try std.testing.expectEqual(@as(u32, 0x100), decoded.periphs[0].old_val);
    try std.testing.expectEqual(@as(u32, 0x200), decoded.periphs[0].new_val);
}

test "diff wire rejects truncated buffer" {
    const short_buf = [_]u8{ 1, 0, 0, 0 };
    try std.testing.expectError(error.Truncated, diff_wire.decode(std.testing.allocator, &short_buf));
}

test "diff wire carries the frame count and each side's position" {
    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try diff_wire.encodeSides(&writer, 7, .{ .branch = 1, .r = 40 }, .{ .branch = 2, .r = 90 }, &.{}, &.{}, &.{});
    var decoded = try diff_wire.decode(std.testing.allocator, writer.buffered());
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 7), decoded.frames);
    try std.testing.expectEqual(@as(u32, 1), decoded.a.branch);
    try std.testing.expectEqual(@as(u64, 90), decoded.b.r);
}
