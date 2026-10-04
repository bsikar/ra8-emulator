//! Covers src/periph/camera/image_source.zig: a picture on disk picked up by
//! its magic bytes, converted to whatever FORMAT CONTROL says at each
//! capture, and written by the CEU into the firmware's buffer pixel for pixel.
const std = @import("std");
const ra8 = @import("ra8");

const ceu = ra8.periph.ceu;
const camera = ceu.camera;
const still = camera.still;
const engine = ra8.core.engine;
const allocator = std.testing.allocator;

/// A 2x2 P6 picture: red, green / blue, white.
const ppm_bytes = "P6\n2 2\n255\n" ++ [_]u8{ 255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255 };

/// The same picture as a bottom-up 24-bit BMP (rows padded to 8 bytes).
fn bmpBytes() [70]u8 {
    var b = [_]u8{0} ** 70;
    b[0] = 'B';
    b[1] = 'M';
    std.mem.writeInt(u32, b[2..6], 70, .little);
    std.mem.writeInt(u32, b[10..14], 54, .little);
    std.mem.writeInt(u32, b[14..18], 40, .little);
    std.mem.writeInt(i32, b[18..22], 2, .little);
    std.mem.writeInt(i32, b[22..26], 2, .little);
    std.mem.writeInt(u16, b[26..28], 1, .little);
    std.mem.writeInt(u16, b[28..30], 24, .little);
    // Bottom row first, pixels in B, G, R order.
    @memcpy(b[54..60], &[_]u8{ 255, 0, 0, 255, 255, 255 });
    @memcpy(b[62..68], &[_]u8{ 0, 0, 255, 0, 255, 0 });
    return b;
}

/// RGB565 little-endian bytes of red, green / blue, white.
const rgb565_rows = [2][4]u8{ .{ 0x00, 0xF8, 0xE0, 0x07 }, .{ 0x1F, 0x00, 0xFF, 0xFF } };

fn writeFile(dir: std.fs.Dir, name: []const u8, bytes: []const u8) !void {
    try dir.writeFile(.{ .sub_path = name, .data = bytes });
}

fn loadFrom(dir: std.testing.TmpDir, name: []const u8, format_control: *const u8) !*still.ImageSource {
    const path = try dir.dir.realpathAlloc(allocator, name);
    defer allocator.free(path);
    return still.ImageSource.load(allocator, path, format_control);
}

test "FORMAT CONTROL picks RGB565 for 0x6x and YUV422 otherwise" {
    try std.testing.expectEqual(camera.convert.Format.rgb565, still.formatFor(0x6F));
    try std.testing.expectEqual(camera.convert.Format.rgb565, still.formatFor(0x61));
    try std.testing.expectEqual(camera.convert.Format.yuv422, still.formatFor(0x30));
    try std.testing.expectEqual(camera.convert.Format.yuv422, still.formatFor(0x00));
}

test "a PPM and a BMP of the same picture fill the same RGB565 bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ppm", ppm_bytes);
    const bmp = bmpBytes();
    try writeFile(tmp.dir, "b.dat", &bmp); // no extension: the magic bytes decide
    var format_control: u8 = 0x6F;
    for ([_][]const u8{ "a.ppm", "b.dat" }) |name| {
        const loaded = try loadFrom(tmp, name, &format_control);
        const source = loaded.source();
        defer source.close();
        source.frame(0, .{ .width = 4, .lines = 2 });
        for (rgb565_rows, 0..) |expected, row| {
            var line: [4]u8 = undefined;
            source.fill(@intCast(row), 0, &line);
            try std.testing.expectEqualSlices(u8, &expected, &line);
        }
    }
}

test "the format is read again at each capture" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ppm", ppm_bytes);
    var format_control: u8 = 0x6F;
    const loaded = try loadFrom(tmp, "a.ppm", &format_control);
    const source = loaded.source();
    defer source.close();
    format_control = 0x30;
    source.frame(0, .{ .width = 4, .lines = 2 });
    var line: [4]u8 = undefined;
    source.fill(0, 0, &line);
    const red = camera.convert.Rgb{ .r = 255, .g = 0, .b = 0 };
    const green = camera.convert.Rgb{ .r = 0, .g = 255, .b = 0 };
    try std.testing.expectEqualSlices(u8, &camera.convert.yuyv(red, green), &line);
}

test "a file no decoder claims and a missing file are refused" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "x.txt", "hello");
    var format_control: u8 = 0x30;
    try std.testing.expectError(error.Unsupported, loadFrom(tmp, "x.txt", &format_control));
    try std.testing.expectError(error.FileNotFound, still.ImageSource.load(allocator, "/nonexistent/ra8.png", &format_control));
}

test "an armed CEU capture writes the picture's pixels into the buffer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ppm", ppm_bytes);
    var format_control: u8 = 0x6F;
    const loaded = try loadFrom(tmp, "a.ppm", &format_control);
    var core = try engine.Engine.open();
    defer core.close();
    const base: u32 = 0x6800_0000;
    try core.map(base, 0x1000);
    var unit = ceu.Ceu.init();
    unit.memory = .{ .engine = core };
    unit.source = loaded.source();
    defer unit.source.close();
    unit.write(ceu.win_base + ceu.off.capwr, 4, 4 | 2 << ceu.field.vertical_shift);
    unit.write(ceu.win_base + ceu.off.cdwdr, 4, 4);
    unit.write(ceu.win_base + ceu.off.cdayr, 4, base);
    unit.write(ceu.win_base + ceu.off.capsr, 4, ceu.field.capture_enable);
    try std.testing.expectEqual(@as(u32, 1), unit.frames);
    var buffer: [8]u8 = undefined;
    try core.read(base, &buffer);
    try std.testing.expectEqualSlices(u8, &(rgb565_rows[0] ++ rgb565_rows[1]), &buffer);
}
