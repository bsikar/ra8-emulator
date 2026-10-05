//! RA8EMU-659: guest memory saved into a snapshot and loaded into a fresh
//! store reads back byte-identical.
const std = @import("std");
const ra8 = @import("ra8");
const file = ra8.snapshot.file;
const memory = ra8.snapshot.memory;
const memmap = ra8.core.memmap;

const window_base: u32 = 0x9000_0000;

fn put(store: *const memory.Store, address: u32, text: []const u8) void {
    @memcpy(store.span(address, text.len).?, text);
}

fn snapshot(store: *const memory.Store, list: *std.ArrayList(u8)) !void {
    try file.writeHeader(list.writer());
    try memory.save(store, list.writer());
}

fn restore(bytes: []const u8) !memory.Store {
    var store = try memory.Store.init(null);
    errdefer store.deinit();
    const section = (try file.Reader.find(bytes, .memory)).?;
    try memory.load(&store, section.payload);
    return store;
}

test "every region and a mapped window come back byte-identical" {
    var first = try memory.Store.init(null);
    defer first.deinit();
    try first.map(window_base, 0x2000);
    put(&first, memmap.mram_base + 0x10, "flash");
    put(&first, memmap.sram_base + 0x1234, "sram");
    put(&first, memmap.sdram_end - 4, "end!");
    put(&first, window_base + 0x1ffc, "win!");
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    try snapshot(&first, &list);
    var second = try restore(list.items);
    defer second.deinit();
    for (memmap.ram) |entry| {
        try std.testing.expectEqualSlices(u8, first.region(entry.base).?, second.region(entry.base).?);
    }
    try std.testing.expectEqualSlices(u8, first.span(window_base, 0x2000).?, second.span(window_base, 0x2000).?);
    try std.testing.expectEqualStrings("sram", second.span(memmap.ns_sram_base + 0x1234, 4).?);
}

test "only non-zero pages are written" {
    var store = try memory.Store.init(null);
    defer store.deinit();
    put(&store, memmap.sram_base, "x");
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    try snapshot(&store, &list);
    try std.testing.expect(list.items.len < 2 * memory.page);
}

test "a second core saves its own regions, not the SRAM it borrows" {
    var first = try memory.Store.init(null);
    defer first.deinit();
    var second = try memory.Store.init(&first);
    defer second.deinit();
    put(&first, memmap.sram_base, "shared");
    put(&second, memmap.mram_base, "cpu1");
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    try snapshot(&second, &list);
    var back = try restore(list.items);
    defer back.deinit();
    try std.testing.expectEqualStrings("cpu1", back.span(memmap.mram_base, 4).?);
    try std.testing.expectEqual(@as(u8, 0), back.span(memmap.sram_base, 1).?[0]);
}

test "a region whose size changed is refused" {
    var store = try memory.Store.init(null);
    defer store.deinit();
    var payload: [16]u8 = undefined;
    for ([_]u32{ 1, memmap.sram_base, 4, 0 }, 0..) |value, index| {
        std.mem.writeInt(u32, payload[index * 4 ..][0..4], value, .little);
    }
    try std.testing.expectError(error.SizeMismatch, memory.load(&store, &payload));
    try std.testing.expectError(error.Truncated, memory.load(&store, payload[0..6]));
}
