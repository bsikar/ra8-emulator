//! Active command bytes and counters, without undefined buffer tails.
const std = @import("std");
const fields = @import("ra8_snapshot").fields;
const Modem = @import("modem.zig").Modem;

pub fn writePayload(writer: *std.Io.Writer, modem: *const Modem) !void {
    if (modem.len > modem.line.len) return error.BadValue;
    var copy = modem.*;
    @memset(copy.line[copy.len..], 0);
    try fields.write(writer, copy);
}

pub fn readPayload(modem: *Modem, cursor: *fields.Cursor) fields.Error!void {
    const copy = try fields.read(Modem, cursor);
    if (!cursor.done() or copy.len > copy.line.len) return error.BadValue;
    modem.* = copy;
}
