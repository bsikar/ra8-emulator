//! RA8EMU-664: both SD cards saved busy, with written blocks, and loaded
//! into fresh cards match byte for byte and read back the same data.
const std = @import("std");
const ra8 = @import("ra8");
const periph = ra8.periph;
const file = ra8.snapshot.file;
const sd = ra8.snapshot.sd;

const Stand = struct {
    sd: periph.sd_card.Card,
    card: periph.sdhi.Sdhi,

    fn init() Stand {
        const allocator = std.testing.allocator;
        return .{ .sd = periph.sd_card.Card.init(allocator), .card = periph.sdhi.Sdhi.init(allocator) };
    }

    fn deinit(self: *Stand) void {
        self.sd.deinit();
        self.card.deinit();
    }
};

fn filled(byte: u8) [512]u8 {
    return @splat(byte);
}

fn busy() !Stand {
    var board = Stand.init();
    errdefer board.deinit();
    try std.testing.expect(board.sd.img.write(7, &filled(0xA5)));
    try std.testing.expect(board.sd.img.write(2, &filled(0x3C)));
    board.sd.ready = true;
    board.sd.commands = 12;
    board.sd.erase_lo = 4;
    try std.testing.expect(board.card.card.write(40, &filled(0x77)));
    board.card.card.state = .tran;
    board.card.reads = 3;
    board.card.regs[2] = 0xDEAD;
    return board;
}

fn saved(board: *const Stand, list: *std.ArrayList(u8)) !void {
    try file.writeHeader(list.writer());
    try sd.save(board, list.writer());
}

test "both cards round-trip byte for byte and read back their blocks" {
    var board = try busy();
    defer board.deinit();
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    try saved(&board, &list);
    var fresh = Stand.init();
    defer fresh.deinit();
    try std.testing.expect(fresh.sd.img.write(9, &filled(1)));
    try sd.load(&fresh, list.items);
    var again = std.ArrayList(u8).init(std.testing.allocator);
    defer again.deinit();
    try saved(&fresh, &again);
    try std.testing.expectEqualSlices(u8, list.items, again.items);
    var out: [512]u8 = undefined;
    try std.testing.expect(fresh.sd.img.read(7, &out));
    try std.testing.expectEqual(@as(u8, 0xA5), out[511]);
    try std.testing.expect(fresh.sd.img.read(9, &out));
    try std.testing.expectEqual(@as(u8, 0), out[0]);
    try std.testing.expectEqual(@as(u32, 1), fresh.card.card.held());
    try std.testing.expect(fresh.card.card.read(40, &out));
    try std.testing.expectEqual(@as(u8, 0x77), out[100]);
}

test "a block past capacity or out of order is BadValue and nothing changes" {
    var board = try busy();
    defer board.deinit();
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    try saved(&board, &list);
    var fresh = Stand.init();
    defer fresh.deinit();
    fresh.sd.commands = 5;
    const bad = try std.testing.allocator.dupe(u8, list.items);
    defer std.testing.allocator.free(bad);
    // The SPI card's blocks are written 2 then 7; renumber the first to 9
    // (out of order), then past the card's end.
    const first = std.mem.indexOf(u8, bad, &[_]u8{ 2, 0, 0, 0 } ++ @as([4]u8, @splat(0x3C))).?;
    std.mem.writeInt(u32, bad[first..][0..4], 9, .little);
    try std.testing.expectError(error.BadValue, sd.load(&fresh, bad));
    std.mem.writeInt(u32, bad[first..][0..4], 0xFFFF_FFF0, .little);
    try std.testing.expectError(error.BadValue, sd.load(&fresh, bad));
    try std.testing.expectEqual(@as(u32, 5), fresh.sd.commands);
    try std.testing.expectEqual(@as(usize, 0), fresh.sd.img.held());
}

test "a missing section or a cut payload leaves both cards untouched" {
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    try file.writeHeader(list.writer());
    var fresh = Stand.init();
    defer fresh.deinit();
    fresh.card.reads = 9;
    try std.testing.expectError(error.Missing, sd.load(&fresh, list.items));
    var board = try busy();
    defer board.deinit();
    list.clearRetainingCapacity();
    try saved(&board, &list);
    try std.testing.expect(std.meta.isError(sd.load(&fresh, list.items[0 .. list.items.len - 1])));
    try std.testing.expectEqual(@as(u32, 9), fresh.card.reads);
    try std.testing.expectEqual(@as(u32, 0), fresh.card.card.held());
}
