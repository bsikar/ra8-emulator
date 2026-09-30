//! Covers src/periph/glcdc_blend.zig: what each graphics layer contributes
//! to the panel, and what happens where two of them overlap.
const std = @import("std");
const ra8 = @import("ra8");

const blend = ra8.periph.glcdc_blend;

fn layer() blend.Layer {
    var stage = blend.Layer{};
    // Driven, displayed, a 4x4 rectangle at the panel origin.
    stage.ab1 = blend.field.grcdispon | @intFromEnum(blend.Display.shown);
    stage.ab2 = 4 << blend.field.size_shift;
    stage.ab3 = 4 << blend.field.size_shift;
    return stage;
}

test "a size and position pair unpacks into a rectangle" {
    const rect = blend.Rect.fromPair(
        (10 << blend.field.size_shift) | 3,
        (20 << blend.field.size_shift) | 5,
    );
    try std.testing.expectEqual(@as(u32, 5), rect.left);
    try std.testing.expectEqual(@as(u32, 3), rect.top);
    try std.testing.expectEqual(@as(u32, 20), rect.width);
    try std.testing.expectEqual(@as(u32, 10), rect.height);
}

test "a zero-sized rectangle covers nothing" {
    const rect = blend.Rect{ .left = 0, .top = 0, .width = 0, .height = 4 };
    try std.testing.expect(!rect.covers(0, 0));
}

test "a rectangle covers its own span and stops at the edge" {
    const rect = blend.Rect{ .left = 2, .top = 1, .width = 3, .height = 2 };
    try std.testing.expect(rect.covers(2, 1));
    try std.testing.expect(rect.covers(4, 2));
    try std.testing.expect(!rect.covers(5, 2));
    try std.testing.expect(!rect.covers(4, 3));
    try std.testing.expect(!rect.covers(1, 1));
}

test "AB1 decodes into the display mode the driver wrote" {
    var stage = blend.Layer{};
    stage.ab1 = 3;
    try std.testing.expectEqual(blend.Display.blended, stage.display());
    stage.ab1 = 1;
    try std.testing.expectEqual(blend.Display.transparent, stage.display());
    stage.ab1 = 2 | blend.field.grcdispon;
    try std.testing.expectEqual(blend.Display.shown, stage.display());
    try std.testing.expect(stage.driven());
}

test "a layer that is not driven contributes nothing" {
    var stage = layer();
    stage.ab1 &= ~blend.field.grcdispon;
    try std.testing.expectEqual(@as(?u32, null), stage.contribution(0xFF00_FF00, 0, 0));
}

test "a transparent layer stands aside and the miss is counted" {
    var stage = layer();
    stage.ab1 = blend.field.grcdispon | @intFromEnum(blend.Display.transparent);
    try std.testing.expectEqual(@as(?u32, null), stage.contribution(0xFF00_FF00, 1, 1));
    try std.testing.expectEqual(@as(u32, 1), stage.hidden);
    try std.testing.expectEqual(@as(u32, 0), stage.shown);
}

test "outside its rectangle a layer contributes nothing at all" {
    var stage = layer();
    try std.testing.expectEqual(@as(?u32, null), stage.contribution(0xFF00_FF00, 9, 0));
    try std.testing.expectEqual(@as(u32, 0), stage.hidden);
}

test "a displayed layer hands back its pixel fully opaque" {
    var stage = layer();
    const shown = stage.contribution(0x0012_3456, 0, 0).?;
    try std.testing.expectEqual(@as(u32, 0xFF12_3456), shown);
    try std.testing.expectEqual(@as(u32, 1), stage.shown);
}

test "a blended layer keeps the alpha its own pixel carries" {
    var stage = layer();
    stage.ab1 = blend.field.grcdispon | @intFromEnum(blend.Display.blended);
    const shown = stage.contribution(0x8012_3456, 0, 0).?;
    try std.testing.expectEqual(@as(u32, 0x8012_3456), shown);
}

test "a blended pixel with no alpha of its own takes ARCDEF" {
    var stage = layer();
    stage.ab1 = blend.field.grcdispon | @intFromEnum(blend.Display.blended);
    stage.ab7 = 0x40 << blend.field.arcdef_shift;
    const shown = stage.contribution(0x0012_3456, 0, 0).?;
    try std.testing.expectEqual(@as(u32, 0x4012_3456), shown);
}

test "a fully transparent blended pixel drops out and is counted hidden" {
    var stage = layer();
    stage.ab1 = blend.field.grcdispon | @intFromEnum(blend.Display.blended);
    try std.testing.expectEqual(@as(?u32, null), stage.contribution(0x0012_3456, 0, 0));
    try std.testing.expectEqual(@as(u32, 1), stage.hidden);
}

test "the alpha rectangle applies ARCDEF where it covers, and only there" {
    var stage = layer();
    stage.ab1 = blend.field.grcdispon | blend.field.arcon | @intFromEnum(blend.Display.blended);
    stage.ab7 = 0x20 << blend.field.arcdef_shift;
    // A 1x1 alpha rectangle at the origin.
    stage.ab4 = 1 << blend.field.size_shift;
    stage.ab5 = 1 << blend.field.size_shift;
    try std.testing.expectEqual(@as(u32, 0x2012_3456), stage.contribution(0xFF12_3456, 0, 0).?);
    try std.testing.expectEqual(@as(u32, 0xFF12_3456), stage.contribution(0xFF12_3456, 1, 1).?);
}

test "a keyed pixel becomes the replacement colour and is counted" {
    var stage = layer();
    stage.ab7 = blend.field.ckon;
    stage.ab8 = 0x0012_3456;
    stage.ab9 = 0xFFAA_BBCC;
    try std.testing.expectEqual(@as(u32, 0xFFAA_BBCC), stage.contribution(0xFF12_3456, 0, 0).?);
    try std.testing.expectEqual(@as(u32, 1), stage.keyed);
    // A colour that is not the key is left alone.
    try std.testing.expectEqual(@as(u32, 0xFF99_9999), stage.contribution(0x0099_9999, 1, 0).?);
    try std.testing.expectEqual(@as(u32, 1), stage.keyed);
}

test "chroma keying off leaves the key colour alone" {
    var stage = layer();
    stage.ab8 = 0x0012_3456;
    stage.ab9 = 0xFFAA_BBCC;
    try std.testing.expectEqual(@as(u32, 0xFF12_3456), stage.contribution(0xFF12_3456, 0, 0).?);
    try std.testing.expectEqual(@as(u32, 0), stage.keyed);
}

test "a write lands in the blend register it names, and nowhere else" {
    var stage = blend.Layer{};
    try std.testing.expect(stage.latch(blend.off.ab1, 0x1234));
    try std.testing.expect(stage.latch(blend.off.base, 0x00FF_0000));
    try std.testing.expect(!stage.latch(0x0C, 0xDEAD));
    try std.testing.expectEqual(@as(u32, 0x1234), stage.ab1);
    try std.testing.expectEqual(@as(u32, 0x00FF_0000), stage.base_colour);
}

test "an unprogrammed blend stage is quiet, and the implied one is not" {
    const stage = blend.Layer{};
    try std.testing.expect(stage.quiet());
    const default = blend.implied(480, 272);
    try std.testing.expect(!default.quiet());
    try std.testing.expect(default.driven());
    try std.testing.expectEqual(blend.Display.shown, default.display());
    try std.testing.expectEqual(@as(u32, 480), default.rect().width);
    try std.testing.expectEqual(@as(u32, 272), default.rect().height);
}

test "source-over leaves an opaque top, an empty top, and blends between" {
    try std.testing.expectEqual(@as(u32, 0xFF11_2233), blend.over(0xFF11_2233, 0xFF00_0000));
    try std.testing.expectEqual(@as(u32, 0xFF44_5566), blend.over(0x0011_2233, 0xFF44_5566));
    // Half of white over black is mid grey, and the result is opaque.
    const mixed = blend.over(0x80FF_FFFF, 0xFF00_0000);
    try std.testing.expectEqual(@as(u32, 0xFF), mixed >> 24);
    try std.testing.expectEqual(@as(u32, 0x80), mixed & 0xFF);
}
