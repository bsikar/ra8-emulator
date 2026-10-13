//! Covers src/interfaces/render/gfx_mono.zig (RA8EMU-1169): the mono face's
//! cells sit in the shared font atlas below the sans rows, every printable
//! glyph has ink, outside characters show '?', and drawn text lands in the
//! frame through the one atlas.
const std = @import("std");
const ra8 = @import("ra8");
const font = ra8.render.font;
const mono = ra8.render.mono_font;
const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;
const Color = draw_list.Color;

fn at(x: u32, y: u32) u8 {
    return font.atlas.coverage[y * font.atlas.width + x];
}

fn lit(char: u8) u32 {
    const origin = mono.cell(char);
    var count: u32 = 0;
    for (0..mono.glyph_h) |row| for (0..mono.glyph_w) |column| {
        if (at(origin.x + @as(u32, @intCast(column)), origin.y + @as(u32, @intCast(row))) != 0) count += 1;
    };
    return count;
}

test "the mono cells sit below the sans rows in the shared atlas" {
    try std.testing.expectEqual(@as(u32, 128), font.atlas.width);
    try std.testing.expectEqual(@as(u32, 192), font.atlas.height);
    try std.testing.expectEqual(@as(u32, 96), mono.origin_y);
    try std.testing.expectEqual(mono.Cell{ .x = 0, .y = 96 }, mono.cell(' '));
}

test "every printable mono glyph but space has ink" {
    try std.testing.expectEqual(@as(u32, 0), lit(' '));
    var char: u8 = mono.first + 1;
    while (char <= mono.last) : (char += 1) try std.testing.expect(lit(char) > 0);
}

test "the mono face is a second face, not a copy of the sans rows" {
    const sans_origin = font.cell('0');
    const mono_origin = mono.cell('0');
    var same: u32 = 0;
    for (0..mono.glyph_h) |row| for (0..mono.glyph_w) |column| {
        const sans_bit = at(sans_origin.x + @as(u32, @intCast(column)), sans_origin.y + @as(u32, @intCast(row)));
        const mono_bit = at(mono_origin.x + @as(u32, @intCast(column)), mono_origin.y + @as(u32, @intCast(row)));
        if (sans_bit == mono_bit) same += 1;
    };
    try std.testing.expect(same < mono.glyph_h * mono.glyph_w);
}

test "characters outside printable ASCII show as a question mark" {
    try std.testing.expectEqual(mono.cell('?'), mono.cell(0x07));
    try std.testing.expectEqual(mono.cell('?'), mono.cell(0xC3));
}

test "text fits by whole cells" {
    try std.testing.expectEqual(@as(u32, 40), mono.textWidth(5));
    try std.testing.expectEqualStrings("2000", mono.fit("2000_0100", 35));
    try std.testing.expectEqualStrings("", mono.fit("2000_0100", 5));
}

test "drawn mono text lands in the frame through the shared atlas" {
    const red = Color.rgb(255, 0, 0);
    var list = draw_list.DrawList.init(std.testing.allocator, 40, 20);
    defer list.deinit();
    var frame = try raster.Framebuffer.init(std.testing.allocator, 40, 20);
    defer frame.deinit(std.testing.allocator);
    try mono.draw(&list, 1, 1, "1I", red);
    try std.testing.expectEqual(@as(usize, 2), list.commands.items.len);
    raster.draw(&frame, &list, font.atlas);
    var ink: u32 = 0;
    for (0..20) |y| for (0..40) |x| {
        if (frame.at(@intCast(x), @intCast(y)).a != 0) ink += 1;
    };
    try std.testing.expect(ink > 0);
}
