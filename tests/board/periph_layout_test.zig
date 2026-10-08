//! Host tests for the peripheral layouts (RA8EMU-818): registers come from
//! each model's own `off` namespace in offset order with its declared
//! width, every paired name is one a fresh board's bus really holds, and
//! the listings print blocks and registers one per line.
const std = @import("std");
const ra8 = @import("ra8");
const layout = ra8.board.periph_layout;
const rtc = ra8.periph.rtc;
const Board = ra8.board.Board;

test "RTC's registers come from its off namespace, in offset order, one byte wide" {
    const found = layout.registers("rtc").?;
    try std.testing.expectEqualStrings("r64cnt", found[0].name);
    try std.testing.expectEqual(@as(u32, 0x00), found[0].offset);
    try std.testing.expectEqualStrings("seccnt", found[1].name);
    try std.testing.expectEqual(rtc.off.seccnt, found[1].offset);
    try std.testing.expectEqualStrings("rcr4", found[found.len - 1].name);
    try std.testing.expectEqual(@as(u32, 0x28), found[found.len - 1].offset);
    var last: u32 = 0;
    for (found) |register| {
        try std.testing.expect(register.offset >= last);
        try std.testing.expectEqual(@as(u8, 1), register.width);
        last = register.offset;
    }
    inline for (@typeInfo(rtc.off).@"struct".decl_names) |name| {
        var seen = false;
        for (found) |register| {
            if (std.mem.eql(u8, register.name, name)) {
                try std.testing.expectEqual(@field(rtc.off, name), register.offset);
                seen = true;
            }
        }
        try std.testing.expect(seen);
    }
    try std.testing.expectEqual(@as(?[]const layout.Register, null), layout.registers("nosuch"));
}

test "a model with no declared width gives 0, printed as ?" {
    const found = layout.registers("IWDT").?;
    for (found) |register| try std.testing.expectEqual(@as(u8, 0), register.width);
    var out: [512]u8 = undefined;
    const text = try layout.writeRegisters("IWDT", &out);
    try std.testing.expect(std.mem.startsWith(u8, text, "rr 0x00 ?\n"));
    try std.testing.expectError(error.UnknownBlock, layout.writeRegisters("nosuch", &out));
    try std.testing.expectError(error.NoSpaceLeft, layout.writeRegisters("RTC", out[0..4]));
}

test "every paired name is the one its model's block reports" {
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    const reported = [_][]const u8{ board.clock.block().name, board.interval.block().name, board.heartbeat.block().name };
    for (layout.layouts, reported) |paired, name| try std.testing.expectEqualStrings(name, paired.block);
}

test "the block listing prints one line per block on the bus" {
    var bus = ra8.periph.registry.Bus.init(std.testing.allocator);
    defer bus.deinit();
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    try bus.add(board.clock.block());
    try bus.add(board.heartbeat.block());
    var out: [256]u8 = undefined;
    const text = try layout.writeBlocks(&bus, &out);
    const iwdt = board.heartbeat.block();
    var want: [128]u8 = undefined;
    const expected = try std.fmt.bufPrint(&want, "RTC 0x40202000 0x80\nIWDT 0x{X:0>8} 0x{X}\n", .{ iwdt.base, iwdt.size });
    try std.testing.expectEqualStrings(expected, text);
    try std.testing.expectEqual(@as(usize, 2), layout.blocks(&bus).len);
    try std.testing.expectError(error.NoSpaceLeft, layout.writeBlocks(&bus, out[0..8]));
}
