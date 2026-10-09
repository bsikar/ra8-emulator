//! The board's two SD cards in a snapshot (RA8EMU-664): the SPI-mode card
//! on SCI0 and the SD host controller with its card, as one `sd` section.
//!
//! Each card's plain state goes through fields.zig and its written blocks
//! through blocks.zig. Not saved: the card's line on SCI0 (a pointer to the
//! card, wiring) and the volume `--sd-new` formatted (run report only).
const std = @import("std");
const file = @import("file.zig");
const fields = @import("fields.zig");
const blocks = @import("blocks.zig");

pub const Error = file.Error || fields.Error || error{ Missing, OutOfMemory };

const store_wiring = .{ "allocator", "blocks" };

pub fn save(board: anytype, writer: anytype) !void {
    var counter: std.Io.Writer.Discarding = .init(&.{});
    try body(&counter.writer, board);
    try file.writeSectionHeader(writer, .sd, counter.fullCount());
    try body(writer, board);
}

fn body(writer: anytype, board: anytype) !void {
    try fields.writeExcept(writer, board.sd, .{"img"});
    try fields.writeExcept(writer, board.sd.img, store_wiring);
    try blocks.write(writer, &board.sd.img.blocks);
    try fields.writeExcept(writer, board.card, .{"card"});
    try fields.writeExcept(writer, board.host_card, store_wiring);
    try blocks.write(writer, &board.host_card.blocks);
}

/// All or nothing: both cards change only once the whole section read
/// cleanly, every index is inside its buffer and both block maps are built.
pub fn load(board: anytype, bytes: []const u8) Error!void {
    const section = try file.Reader.find(bytes, .sd) orelse return Error.Missing;
    var cursor: fields.Cursor = .{ .bytes = section.payload };
    var spi = board.sd;
    try fields.readOver(&cursor, &spi, .{"img"});
    try fields.readOver(&cursor, &spi.img, store_wiring);
    const spi_list = try blocks.List.read(&cursor, spi.img.capacity_blocks);
    var host = board.card;
    try fields.readOver(&cursor, &host, .{"card"});
    var disk = board.host_card;
    try fields.readOver(&cursor, &disk, store_wiring);
    const host_list = try blocks.List.read(&cursor, disk.capacity_blocks);
    if (!cursor.done() or !fits(&spi, &host)) return Error.BadValue;
    var spi_map = try spi_list.build(spi.img.allocator);
    errdefer blocks.free(&spi_map);
    const host_map = try host_list.build(disk.allocator);
    blocks.free(&board.sd.img.blocks);
    blocks.free(&board.host_card.blocks);
    spi.img.blocks = spi_map;
    disk.blocks = host_map;
    board.sd = spi;
    board.card = host;
    board.host_card = disk;
}

fn fits(spi: anytype, host: anytype) bool {
    const reply = spi.reply;
    return spi.cmd_len <= spi.cmd.len and reply.len <= reply.buf.len and
        reply.pos <= reply.len and host.data.word_idx <= block_bytes_words;
}

const block_bytes_words = blocks.block_bytes / 4;
