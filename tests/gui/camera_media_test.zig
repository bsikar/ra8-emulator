//! Covers src/gui/camera_media.zig: the project directory's pictures and
//! clips found by their first bytes, sorted, everything else left out.
const std = @import("std");
const ra8 = @import("ra8");
const media = ra8.gui.camera_media;

fn write(dir: std.fs.Dir, name: []const u8, bytes: []const u8) !void {
    try dir.writeFile(.{ .sub_path = name, .data = bytes });
}

test "a file's first bytes decide its kind, not its name" {
    try std.testing.expectEqual(media.Kind.image, media.classify("\x89PNG\r\n\x1a\n....").?);
    try std.testing.expectEqual(media.Kind.image, media.classify("BM......").?);
    try std.testing.expectEqual(media.Kind.image, media.classify("P6\n4 4\n255\n").?);
    try std.testing.expectEqual(media.Kind.video, media.classify("YUV4MPEG2 W4 H4").?);
    try std.testing.expect(media.classify("hello") == null);
    try std.testing.expect(media.classify("") == null);
}

test "pictures and clips are listed by name and the rest left out" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try write(tmp.dir, "b.png", "\x89PNG\r\n\x1a\nrest");
    try write(tmp.dir, "a.dat", "P6\n2 2\n255\n");
    try write(tmp.dir, "clip.y4m", "YUV4MPEG2 W2 H2 F30:1\n");
    try write(tmp.dir, "notes.png", "not a picture");
    try write(tmp.dir, "empty", "");
    try tmp.dir.makeDir("dir.png");
    var found = try media.list(std.testing.allocator, tmp.dir);
    defer found.deinit();
    try std.testing.expectEqual(@as(usize, 2), found.images.len);
    try std.testing.expectEqualStrings("a.dat", found.images[0]);
    try std.testing.expectEqualStrings("b.png", found.images[1]);
    try std.testing.expectEqual(@as(usize, 1), found.of(.video).len);
    try std.testing.expectEqualStrings("clip.y4m", found.of(.video)[0]);
}

test "an empty directory offers nothing" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var found = try media.list(std.testing.allocator, tmp.dir);
    defer found.deinit();
    try std.testing.expectEqual(@as(usize, 0), found.images.len);
    try std.testing.expectEqual(@as(usize, 0), found.videos.len);
}
