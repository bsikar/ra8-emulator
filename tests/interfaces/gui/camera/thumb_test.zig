//! Covers src/interfaces/gui/camera/thumb.zig: the preview a picture or a
//! clip's first frame shrinks to, box-averaged, shape kept, small pictures
//! never enlarged (RA8EMU-1123).
const std = @import("std");
const gui_app = @import("gui_app");

const thumb = gui_app.camera.thumb;

fn write(dir: std.Io.Dir, name: []const u8, bytes: []const u8) !void {
    try dir.writeFile(std.testing.io, .{ .sub_path = name, .data = bytes });
}

test "a small picture loads whole, never enlarged" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const file = "P6\n4 4\n255\n" ++ ("\x10\x20\x30" * *16);
    try write(tmp.dir, "tiny.ppm", file);
    var t = try thumb.load(std.testing.allocator, std.testing.io, tmp.dir, "tiny.ppm");
    defer t.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 4), t.width);
    try std.testing.expectEqual(@as(u32, 4), t.height);
    const p = t.pixels[0];
    try std.testing.expectEqual(@as(u8, 0x10), p.r);
    try std.testing.expectEqual(@as(u8, 0x20), p.g);
    try std.testing.expectEqual(@as(u8, 0x30), p.b);
}

test "a big picture shrinks to the side keeping its shape" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const w: u32 = 64;
    const h: u32 = 32;
    var body: [w * h * 3]u8 = undefined;
    for (&body) |*b| b.* = 0x80;
    var header_buf: [32]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf, "P6\n{d} {d}\n255\n", .{ w, h });
    var file: [header.len + body.len]u8 = undefined;
    @memcpy(file[0..header.len], header);
    @memcpy(file[header.len..], &body);
    try write(tmp.dir, "big.ppm", &file);
    var t = try thumb.load(std.testing.allocator, std.testing.io, tmp.dir, "big.ppm");
    defer t.deinit(std.testing.allocator);
    try std.testing.expectEqual(thumb.side, t.width);
    try std.testing.expectEqual(thumb.side / 2, t.height);
}

test "a clip's first frame is the preview" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const planes = [1]u8{0x10} * *24;
    const file = "YUV4MPEG2 W4 H4 F30:1 Ip A1:1 C420jpeg\n" ++
        "FRAME\n" ++ planes;
    try write(tmp.dir, "clip.y4m", file);
    var t = try thumb.load(std.testing.allocator, std.testing.io, tmp.dir, "clip.y4m");
    defer t.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 4), t.width);
    try std.testing.expectEqual(@as(u32, 4), t.height);
    try std.testing.expectEqual(@as(usize, 16), t.pixels.len);
}

test "garbage is refused, not drawn" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try write(tmp.dir, "no.txt", "not a picture");
    try std.testing.expectError(error.BadHeader, thumb.load(std.testing.allocator, std.testing.io, tmp.dir, "no.txt"));
}
