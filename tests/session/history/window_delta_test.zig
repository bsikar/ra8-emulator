//! Side-state delta tests: XORed runs flip an image both ways, nearby
//! changes fold into one run, a length change keeps both images, and a
//! change outside the core and clock sections marks the board.

const std = @import("std");
const ra8 = @import("ra8");
const delta_mod = ra8.session.history_window_delta;
const file = ra8.board.snapshot.run.file;

const gpa = std.testing.allocator;

/// A tiny stream: a board section (timers), then a core section (cpu).
fn stream(timer: u8, reg: u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try file.writeHeader(&out.writer);
    try file.writeSectionHeader(&out.writer, .timers, 4);
    try out.writer.writeAll(&.{ timer, 0, 0, 0 });
    try file.writeSectionHeader(&out.writer, .cpu, 4);
    try out.writer.writeAll(&.{ reg, 0, 0, reg });
    return gpa.dupe(u8, out.written());
}

test "XORed runs flip an image forward and back" {
    const pre = try stream(1, 2);
    defer gpa.free(pre);
    const post = try stream(1, 9);
    defer gpa.free(post);
    var delta = try delta_mod.encode(gpa, pre, post);
    defer delta.deinit(gpa);
    // Two changed bytes three apart fold into one run.
    try std.testing.expectEqual(@as(usize, 1), delta.runs.len);
    try std.testing.expectEqual(@as(u32, 4), delta.runs[0].len);
    try std.testing.expect(!delta.board);

    var image: std.ArrayList(u8) = .empty;
    defer image.deinit(gpa);
    try image.appendSlice(gpa, pre);
    try delta.flip(gpa, &image, true);
    try std.testing.expectEqualSlices(u8, post, image.items);
    try delta.flip(gpa, &image, false);
    try std.testing.expectEqualSlices(u8, pre, image.items);
}

test "a change outside the core sections marks the board" {
    const pre = try stream(1, 2);
    defer gpa.free(pre);
    const post = try stream(5, 2);
    defer gpa.free(post);
    var delta = try delta_mod.encode(gpa, pre, post);
    defer delta.deinit(gpa);
    try std.testing.expect(delta.board);
    try std.testing.expect(delta.bytes() >= delta.runs.len * @sizeOf(delta_mod.Run) + delta.xor.len and delta.bytes() > 0);
}

test "identical images need no run" {
    const pre = try stream(3, 4);
    defer gpa.free(pre);
    var delta = try delta_mod.encode(gpa, pre, pre);
    defer delta.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), delta.runs.len);
    try std.testing.expect(!delta.board);
}

test "a length change keeps both whole images" {
    const pre = try stream(1, 2);
    defer gpa.free(pre);
    const post = try gpa.alloc(u8, pre.len + 3);
    defer gpa.free(post);
    @memcpy(post[0..pre.len], pre);
    @memset(post[pre.len..], 7);
    var delta = try delta_mod.encode(gpa, pre, post);
    defer delta.deinit(gpa);
    try std.testing.expect(delta.board);

    var image: std.ArrayList(u8) = .empty;
    defer image.deinit(gpa);
    try image.appendSlice(gpa, pre);
    try delta.flip(gpa, &image, true);
    try std.testing.expectEqualSlices(u8, post, image.items);
    try delta.flip(gpa, &image, false);
    try std.testing.expectEqualSlices(u8, pre, image.items);
}

test "core sections are the cores, clocks, grid and debug units" {
    try std.testing.expect(delta_mod.coreSection(.cpu));
    try std.testing.expect(delta_mod.coreSection(.grid));
    try std.testing.expect(delta_mod.coreSection(.debug_units));
    try std.testing.expect(!delta_mod.coreSection(.timers));
    try std.testing.expect(!delta_mod.coreSection(.fabric));
    try std.testing.expect(!delta_mod.coreSection(.attachments));
}

test "a malformed image fails the encode without leaking its runs" {
    // Equal lengths with a changed byte, but no section header to parse:
    // the board check fails after the runs were taken as an owned slice.
    const pre = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var post = pre;
    post[3] = 9;
    try std.testing.expect(std.meta.isError(delta_mod.encode(gpa, &pre, &post)));
}

test "the delta's byte count is its heap and nothing for the struct" {
    const pre = try stream(1, 2);
    defer gpa.free(pre);
    const post = try stream(1, 3);
    defer gpa.free(post);
    var d = try delta_mod.encode(gpa, pre, post);
    defer d.deinit(gpa);
    try std.testing.expectEqual(d.runs.len * @sizeOf(delta_mod.Run) + d.xor.len, d.bytes());
}
