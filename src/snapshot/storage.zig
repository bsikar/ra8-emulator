//! The board's sparse memories in a snapshot (RA8EMU-674): the option MRAM
//! with its programmed OTP cells and the octal NOR flash behind XSPI0 with
//! its written sectors, as one `storage` section.
//!
//! Plain state goes through fields.zig and the sparse contents through
//! sparse.zig. Not saved, because they are wiring: the guest store the
//! option MRAM writes through to, and the clock-select model the flash
//! controller reads live. A load keeps the target's.
const std = @import("std");
const file = @import("file.zig");
const fields = @import("fields.zig");
const sparse = @import("sparse.zig");
const otp = @import("../periph/mram/mram_otp.zig");
const nor = @import("../periph/xspi/xspi_flash.zig");

pub const Error = file.Error || fields.Error || error{ Missing, OutOfMemory };

const options_wiring = .{ "otp", "memory" };
const flash_wiring = .{ "flash", "octa" };
const Cells = sparse.List(1);
const Sectors = sparse.List(nor.part.sector_len);
const Sector = [nor.part.sector_len]u8;

pub fn save(board: anytype, writer: anytype) !void {
    var counter = std.io.countingWriter(std.io.null_writer);
    try body(counter.writer(), board);
    try file.writeSectionHeader(writer, .storage, counter.bytes_written);
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
    const sectors = &board.flash.flash.sectors;
    const sector_keys = try sparse.sortedKeys(board.flash.flash.allocator, sectors);
    defer board.flash.flash.allocator.free(sector_keys);
    try sparse.writeCount(writer, sector_keys);
    for (sector_keys) |key| {
        try fields.write(writer, key);
        try writer.writeAll(sectors.get(key).?);
    }
}

/// All or nothing: both units change only once the whole section read
/// cleanly, every number is inside its part and both maps are built.
pub fn load(board: anytype, bytes: []const u8) Error!void {
    const section = try file.Reader.find(bytes, .storage) orelse return Error.Missing;
    var cursor: fields.Cursor = .{ .bytes = section.payload };
    var options = board.options;
    try fields.readOver(&cursor, &options, options_wiring);
    const cell_list = try Cells.read(&cursor, inWindow);
    var flash = board.flash;
    try fields.readOver(&cursor, &flash, flash_wiring);
    const sector_list = try Sectors.read(&cursor, inPart);
    const stream = options.stream;
    if (!cursor.done() or stream.len > stream.payload.len) return Error.BadValue;
    var cells = try buildCells(cell_list, board.options.otp.written.allocator);
    errdefer cells.deinit();
    const sectors = try buildSectors(sector_list, board.flash.flash.allocator);
    board.options.otp.written.deinit();
    board.flash.flash.deinit();
    options.otp.written = cells;
    flash.flash.sectors = sectors;
    board.options = options;
    board.flash = flash;
}

fn inWindow(address: u32) bool {
    return address >= otp.window.lo and address < otp.window.hi + otp.window.program_bytes;
}

fn inPart(number: u32) bool {
    return number < nor.part.size / nor.part.sector_len;
}

fn buildCells(list: Cells, allocator: std.mem.Allocator) !std.AutoHashMap(u32, u8) {
    var map = std.AutoHashMap(u32, u8).init(allocator);
    errdefer map.deinit();
    try map.ensureTotalCapacity(list.count);
    var i: u32 = 0;
    while (i < list.count) : (i += 1) map.putAssumeCapacity(list.number(i), list.value(i)[0]);
    return map;
}

fn buildSectors(list: Sectors, allocator: std.mem.Allocator) !std.AutoHashMap(u32, *Sector) {
    var map = std.AutoHashMap(u32, *Sector).init(allocator);
    errdefer freeSectors(&map, allocator);
    try map.ensureTotalCapacity(list.count);
    var i: u32 = 0;
    while (i < list.count) : (i += 1) {
        const sector = try allocator.create(Sector);
        sector.* = list.value(i).*;
        map.putAssumeCapacity(list.number(i), sector);
    }
    return map;
}

fn freeSectors(map: *std.AutoHashMap(u32, *Sector), allocator: std.mem.Allocator) void {
    var it = map.valueIterator();
    while (it.next()) |sector| allocator.destroy(sector.*);
    map.deinit();
}
