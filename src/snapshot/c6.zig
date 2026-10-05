//! The board's ESP32-C6 companion in a snapshot (RA8EMU-687): the reply
//! byte and the esp-hosted link (frames, offset, caps, counters and the
//! reply queue), as one `c6` section.
//!
//! Not saved, because it is wiring: `pins` (the GPIO block init points it
//! at). A load keeps the target board's own.
const std = @import("std");
const file = @import("file.zig");
const fields = @import("fields.zig");

pub const Error = file.Error || fields.Error || error{Missing};

const wiring = .{"pins"};

pub fn save(board: anytype, writer: anytype) !void {
    var counter = std.io.countingWriter(std.io.null_writer);
    try fields.writeExcept(counter.writer(), board.c6, wiring);
    try file.writeSectionHeader(writer, .c6, counter.bytes_written);
    try fields.writeExcept(writer, board.c6, wiring);
}

/// All or nothing: the C6 changes only once the whole section read cleanly
/// and the link's offset, caps and queue fit their buffers.
pub fn load(board: anytype, bytes: []const u8) Error!void {
    const section = try file.Reader.find(bytes, .c6) orelse return Error.Missing;
    var cursor: fields.Cursor = .{ .bytes = section.payload };
    var copy = board.c6;
    try fields.readOver(&cursor, &copy, wiring);
    if (!cursor.done() or !fits(copy.wire)) return Error.BadValue;
    board.c6 = copy;
}

fn fits(wire: anytype) bool {
    const queue = wire.queue;
    return wire.offset <= wire.rx.len and wire.caps_len <= wire.caps.len and
        queue.head < queue.slots.len and queue.len <= queue.slots.len;
}
