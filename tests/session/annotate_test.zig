//! The disassembly annotator: names from the image's own symbol table.
const std = @import("std");
const ra8 = @import("ra8");
const elf = ra8.board.image.elf;
const text = ra8.chip.core.cpu.text.text;
const annotate = ra8.session.annotate;

const Builder = @import("symbol_image.zig").Builder;

fn testingImage(buffer: []u8) !elf.Image {
    const bytes = Builder.build(buffer, &.{ "uart_echo", "g_ticks" }, &.{ 0x0800_0100, 0x2200_0100 });
    return elf.Image.init(bytes);
}

test "an exact symbol names its address" {
    var buffer: [1024]u8 = undefined;
    const image = try testingImage(&buffer);
    try std.testing.expectEqualStrings("uart_echo", annotate.symbolAt(image, 0x0800_0100).?);
    try std.testing.expectEqualStrings("g_ticks", annotate.symbolAt(image, 0x2200_0100).?);
    try std.testing.expectEqual(@as(?[]const u8, null), annotate.symbolAt(image, 0x0800_0500));
}

test "an address inside a sized function is named relative to it" {
    var buffer: [1024]u8 = undefined;
    const bytes = Builder.buildSized(&buffer, &.{"uart_echo"}, &.{0x0800_0100}, &.{0x20});
    const image = try elf.Image.init(bytes);
    var into: text.Text = .{};
    into.put("b.w #0x{x}", .{@as(u32, 0x0800_0108)});
    annotate.line(image, &into);
    try std.testing.expectEqualStrings("b.w #0x8000108 ; uart_echo+0x8", into.slice());
}

test "a branch to a named function is annotated" {
    var buffer: [1024]u8 = undefined;
    const image = try testingImage(&buffer);
    var into: text.Text = .{};
    into.put("b.w #0x{x}", .{@as(u32, 0x0800_0100)});
    annotate.line(image, &into);
    try std.testing.expectEqualStrings("b.w #0x8000100 ; uart_echo", into.slice());
}

test "a load from a named global is annotated" {
    var buffer: [1024]u8 = undefined;
    const image = try testingImage(&buffer);
    var into: text.Text = .{};
    into.put("ldr r1, #0x{x}", .{@as(u32, 0x2200_0100)});
    annotate.line(image, &into);
    try std.testing.expectEqualStrings("ldr r1, #0x22000100 ; g_ticks", into.slice());
}

test "an address the table does not name leaves the line alone" {
    var buffer: [1024]u8 = undefined;
    const image = try testingImage(&buffer);
    var into: text.Text = .{};
    into.put("b.w #0x{x}", .{@as(u32, 0x0800_0500)});
    annotate.line(image, &into);
    try std.testing.expectEqualStrings("b.w #0x8000500", into.slice());
}

test "a line with no address immediate is untouched" {
    var buffer: [1024]u8 = undefined;
    const image = try testingImage(&buffer);
    var into: text.Text = .{};
    into.put("adds r0, r0, #10", .{});
    annotate.line(image, &into);
    try std.testing.expectEqualStrings("adds r0, r0, #10", into.slice());
}

test "a hex immediate that is not a symbol address is untouched" {
    var buffer: [1024]u8 = undefined;
    const image = try testingImage(&buffer);
    var into: text.Text = .{};
    into.put("adds r0, r0, #0x10", .{});
    annotate.line(image, &into);
    try std.testing.expectEqualStrings("adds r0, r0, #0x10", into.slice());
}

// A unit carrying one function and one local with fixed storage, so
// the annotator can name a load from it: a variable whose location is
// DW_OP_addr 0x2000.
const debug_abbrev = [_]u8{
    0x01, 0x11, 0x01, 0x03, 0x08, 0x00, 0x00,
    0x02, 0x2e, 0x01, 0x11, 0x01, 0x12, 0x06,
    0x00, 0x00, 0x04, 0x34, 0x00, 0x03, 0x08,
    0x02, 0x18, 0x00, 0x00,
};

const debug_dies = [_]u8{
    0x01, 'f',  '.',  'c',  0x00,
    0x02, 0x00, 0x01, 0x00, 0x08,
    0x20, 0x00, 0x00, 0x00, 0x04,
    's',  'l',  'o',  't',  0x00,
    0x05, 0x03, 0x00, 0x20, 0x00,
    0x00, 0x00, 0x00,
};

fn debugImage(buffer: []u8) !elf.Image {
    var info: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer info.deinit();
    try info.writer.writeInt(u32, @intCast(7 + debug_dies.len), .little);
    try info.writer.writeInt(u16, 4, .little);
    try info.writer.writeInt(u32, 0, .little);
    try info.writer.writeByte(4);
    try info.writer.writeAll(&debug_dies);
    const bytes = Builder.buildDebug(buffer, &.{"uart_echo"}, &.{0x0800_0100}, info.written(), &debug_abbrev, "");
    return elf.Image.init(bytes);
}

test "a local with fixed storage names its address" {
    var buffer: [2048]u8 = undefined;
    const image = try debugImage(&buffer);
    var into: text.Text = .{};
    into.put("ldr r0, #0x{x}", .{@as(u32, 0x2000)});
    annotate.line(image, &into);
    try std.testing.expectEqualStrings("ldr r0, #0x2000 ; slot", into.slice());
}

test "an address no symbol and no local carries stays alone" {
    var buffer: [2048]u8 = undefined;
    const image = try debugImage(&buffer);
    var into: text.Text = .{};
    into.put("ldr r0, #0x{x}", .{@as(u32, 0x2004)});
    annotate.line(image, &into);
    try std.testing.expectEqualStrings("ldr r0, #0x2004", into.slice());
}
