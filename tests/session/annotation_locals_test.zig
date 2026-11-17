//! Scope and exact-storage checks do not invent names outside supported locations.
const std = @import("std");

const fixture = @import("annotation_fixture.zig");
const ra8 = @import("ra8");
const local_names = ra8.session.annotation_locals;

fn expect(pc: u32, source: []const u8, wanted: []const u8) !void {
    var bytes: [2048]u8 = undefined;
    const image = try fixture.image(&bytes);
    var text: ra8.chip.core.cpu.text.text.Text = .{};
    text.put("{s}", .{source});
    local_names.append(image, pc, &text);
    try std.testing.expectEqualStrings(wanted, text.slice());
}

test "register and frame storage match only within the compiler's scope" {
    try expect(0x100, "movs r0, #1", "movs r0, #1 ; local value");
    try expect(0x100, "ldr r3, [sp, #4]", "ldr r3, [sp, #4] ; local slot");
    try expect(0x110, "movs r0, #1", "movs r0, #1");
    try expect(0x100, "ldr r3, [sp, #8]", "ldr r3, [sp, #8]");
    try expect(0x100, "ldr r3, [sp, #4]!", "ldr r3, [sp, #4]!");
    try expect(0x100, "b #0x120 ; r0", "b #0x120 ; r0");
}

test "nameless DWARF locals are skipped without emitting blank labels" {
    const abbrev = [_]u8{
        1,    0x11, 1, 3,    8, 0,    0,
        2,    0x2e, 1, 0x11, 1, 0x12, 6,
        0x40, 0x18, 0, 0,    4, 0x34, 0,
        3,    8,    2, 0x18, 0, 0,    5,
        0x34, 0,    2, 0x18, 0, 0,
    };
    const dies = [_]u8{
        1,    'a',  '.', 'c',  0,
        2,    0,    1,   0,    0,
        0x10, 0,    0,   0,    1,
        0x5d, 5,    1,   0x50, 4,
        's',  'l',  'o', 't',  0,
        1,    0x50, 0,   0,
    };
    var info: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&info);
    try writer.writeInt(u32, 7 + dies.len, .little);
    try writer.writeInt(u16, 4, .little);
    try writer.writeInt(u32, 0, .little);
    try writer.writeByte(4);
    try writer.writeAll(&dies);
    var bytes: [2048]u8 = undefined;
    const raw = @import("symbol_image.zig").Builder.buildDebug(&bytes, &.{"entry"}, &.{0x100}, writer.buffered(), &abbrev, "");
    const image = try ra8.board.image.elf.Image.init(raw);
    var text: ra8.chip.core.cpu.text.text.Text = .{};
    text.put("movs r0, #1", .{});
    local_names.append(image, 0x100, &text);
    try std.testing.expectEqualStrings("movs r0, #1 ; local slot", text.slice());
}
