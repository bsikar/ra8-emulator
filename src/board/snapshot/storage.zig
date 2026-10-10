//! Option MRAM and the configured OSPI NOR contents in a snapshot.
const std = @import("std");
const file = @import("../../snapshot/file.zig");
const fields = @import("../../snapshot/fields.zig");
const sparse = @import("../../snapshot/sparse.zig");
const otp = @import("../../chip/periph/mram/mram_otp.zig");
const nor = @import("../../components/nor_flash/flash.zig");

pub const Error = file.Error || fields.Error || error{ Missing, OutOfMemory };
const options_wiring = .{ "otp", "memory" };
const flash_wiring = .{ "part", "octa" };
const Cells = sparse.List(1);
const Sectors = sparse.List(nor.part.sector_len);

pub fn save(board: anytype, writer: anytype) !void {
    var counter: std.Io.Writer.Discarding = .init(&.{});
    try body(&counter.writer, board);
    try file.writeSectionHeader(writer, .storage, counter.fullCount());
    try body(writer, board);
}

fn body(writer: anytype, board: anytype) !void {
    try fields.writeExcept(writer, board.options, options_wiring);
    const cells = &board.options.otp.written;
    const cell_keys = try sparse.sortedKeys(cells.allocator, cells);
    defer cells.allocator.free(cell_keys);
    try sparse.writeCount(writer, cell_keys);
    for (cell_keys) |key| {
        try fields.write(writer, key);
        try writer.writeByte(cells.get(key).?);
    }
    try fields.writeExcept(writer, board.flash, flash_wiring);
    try fields.write(writer, board.nor.capacity);
    try fields.write(writer, board.nor.live());
    var sector: [nor.part.sector_len]u8 = undefined;
    for (0..board.nor.capacity / nor.part.sector_len) |index| {
        if (!board.nor.sectorDirty(@intCast(index))) continue;
        try fields.write(writer, @as(u32, @intCast(index)));
        board.nor.readSector(@intCast(index), &sector);
        try writer.writeAll(&sector);
    }
}

/// All-or-nothing: parse and validate both sparse lists before replacing
/// either target, including the selected flash capacity.
pub fn load(board: anytype, bytes: []const u8) Error!void {
    const section = try file.Reader.find(bytes, .storage) orelse return Error.Missing;
    var cursor: fields.Cursor = .{ .bytes = section.payload };
    var options = board.options;
    try fields.readOver(&cursor, &options, options_wiring);
    const cell_list = try Cells.read(&cursor, inWindow);
    var controller = board.flash;
    try fields.readOver(&cursor, &controller, flash_wiring);
    const saved_capacity = try fields.read(u32, &cursor);
    const sector_list = try Sectors.read(&cursor, inMaximumPart);
    const stream = options.stream;
    if (!cursor.done() or stream.len > stream.payload.len) return Error.BadValue;
    if (saved_capacity != board.nor.capacity) return Error.BadValue;
    var i: u32 = 0;
    while (i < sector_list.count) : (i += 1) {
        if (sector_list.number(i) >= board.nor.capacity / nor.part.sector_len) return Error.BadValue;
    }
    var cells = try buildCells(cell_list, board.options.otp.written.allocator);
    errdefer cells.deinit();
    var flash = nor.Flash.init(board.nor.allocator);
    errdefer flash.deinit();
    flash.capacity = board.nor.capacity;
    try flash.resize(flash.capacity);
    i = 0;
    while (i < sector_list.count) : (i += 1) try flash.loadSector(sector_list.number(i), sector_list.value(i));
    board.options.otp.written.deinit();
    board.nor.deinit();
    options.otp.written = cells;
    board.options = options;
    board.flash = controller;
    board.nor = flash;
}

fn inWindow(address: u32) bool {
    return address >= otp.window.lo and address < otp.window.hi + otp.window.program_bytes;
}

fn inMaximumPart(number: u32) bool {
    return number < (256 * 1024 * 1024) / nor.part.sector_len;
}

fn buildCells(list: Cells, allocator: std.mem.Allocator) !std.AutoHashMap(u32, u8) {
    var map = std.AutoHashMap(u32, u8).init(allocator);
    errdefer map.deinit();
    try map.ensureTotalCapacity(list.count);
    var i: u32 = 0;
    while (i < list.count) : (i += 1) map.putAssumeCapacity(list.number(i), list.value(i)[0]);
    return map;
}
