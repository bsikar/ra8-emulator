//! Covers src/periph/camera/pipe_source.zig: frames streamed through a real
//! pipe come back out of the FrameSource, the newest whole frame wins, half
//! a frame is never shown, and an empty pipe or a closed writer returns at
//! once with the last frame held. Unix only; the Windows server is covered in
//! pipe_windows_test.zig.
const std = @import("std");
const builtin = @import("builtin");
const ra8 = @import("ra8");

const camera = ra8.periph.ceu.camera;
const pipe = camera.pipe;
const allocator = std.testing.allocator;

/// The CEU programs RGB565 here; a 2x1 rgb24 frame becomes 4 bytes.
var rgb565: u8 = 0x6F;
const arg = pipe.raw.Arg{ .path = "-", .width = 2, .height = 1, .format = .rgb24 };
const red = [_]u8{ 255, 0, 0, 255, 0, 0 };
const blue = [_]u8{ 0, 0, 255, 0, 0, 255 };
const white = [_]u8{ 255, 255, 255, 255, 255, 255 };

const Ends = struct { source: *pipe.PipeSource, writer: std.posix.fd_t };

fn open() !Ends {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const fds = try std.posix.pipe();
    const source = try pipe.PipeSource.fromFd(allocator, fds[0], true, arg, &rgb565);
    return .{ .source = source, .writer = fds[1] };
}

fn expectLine(source: camera.frame_source.FrameSource, expected: [4]u8) !void {
    source.frame(0, .{ .width = 4, .lines = 1 });
    var line: [4]u8 = undefined;
    source.fill(0, 0, &line);
    try std.testing.expectEqualSlices(u8, &expected, &line);
}

const black_565 = [4]u8{ 0x00, 0x00, 0x00, 0x00 };
const red_565 = [4]u8{ 0x00, 0xF8, 0x00, 0xF8 };
const blue_565 = [4]u8{ 0x1F, 0x00, 0x1F, 0x00 };
const white_565 = [4]u8{ 0xFF, 0xFF, 0xFF, 0xFF };

test "an empty pipe returns at once and the capture is black" {
    const ends = try open();
    defer std.posix.close(ends.writer);
    const source = ends.source.source();
    defer source.close();
    try expectLine(source, black_565);
    try std.testing.expect(!ends.source.closed);
}

test "the newest whole frame wins and half a frame waits for the rest" {
    const ends = try open();
    defer std.posix.close(ends.writer);
    const source = ends.source.source();
    defer source.close();
    _ = try std.posix.write(ends.writer, &red);
    _ = try std.posix.write(ends.writer, &blue);
    _ = try std.posix.write(ends.writer, white[0..4]);
    try expectLine(source, blue_565);
    try std.testing.expectEqual(@as(u64, 2), ends.source.frames);
    _ = try std.posix.write(ends.writer, white[4..]);
    try expectLine(source, white_565);
    try expectLine(source, white_565);
}

test "a closed writer holds the last frame and never stalls the run" {
    const ends = try open();
    const source = ends.source.source();
    defer source.close();
    _ = try std.posix.write(ends.writer, &red);
    std.posix.close(ends.writer);
    try expectLine(source, red_565);
    try std.testing.expect(ends.source.closed);
    try expectLine(source, red_565);
}

test "a writer faster than the run cannot hold one capture forever" {
    const ends = try open();
    defer std.posix.close(ends.writer);
    const source = ends.source.source();
    defer source.close();
    var burst: [6 * (pipe.max_frames_per_capture + 1)]u8 = undefined;
    for (0..pipe.max_frames_per_capture + 1) |at| @memcpy(burst[at * 6 ..][0..6], &red);
    _ = try std.posix.write(ends.writer, &burst);
    try expectLine(source, red_565);
    try std.testing.expectEqual(@as(u64, pipe.max_frames_per_capture), ends.source.frames);
    try expectLine(source, red_565);
    try std.testing.expectEqual(@as(u64, pipe.max_frames_per_capture + 1), ends.source.frames);
}

test "pipe is a registered kind named after its argument" {
    const spec = try camera.registry.parse("pipe:-,2x1,rgb24");
    try std.testing.expectEqual(camera.registry.Kind.pipe, spec.kind);
    try std.testing.expectError(error.BadValue, camera.registry.parse("pipe:-"));
    try std.testing.expectError(error.BadValue, camera.registry.parse("pipe"));
    const named = pipe.labelled(camera.gradient.source(), "-,2x1,rgb24");
    try std.testing.expectEqualStrings("pipe", named.label);
    try std.testing.expectEqualStrings("-,2x1,rgb24", named.detail);
}
