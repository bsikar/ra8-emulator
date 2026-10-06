//! A list of plain units saved as one snapshot section (RA8EMU-662).
//!
//! Each pointee is written through fields.zig, excluding the optional
//! `event_hook` wiring used by live sessions. Loading reads every unit into a
//! copy first and stores them only once the whole payload has read cleanly, so
//! a bad file leaves every unit as it was and a good load preserves the hook.
const std = @import("std");
const file = @import("file.zig");
const fields = @import("fields.zig");

pub const Error = file.Error || fields.Error || error{Missing};

pub fn save(writer: anytype, kind: file.Kind, units: anytype) !void {
    var counter = std.io.countingWriter(std.io.null_writer);
    try body(counter.writer(), units);
    try file.writeSectionHeader(writer, kind, counter.bytes_written);
    try body(writer, units);
}

fn body(writer: anytype, units: anytype) !void {
    inline for (units) |unit| try fields.writeExcept(writer, unit.*, .{"event_hook"});
}

pub fn load(bytes: []const u8, kind: file.Kind, units: anytype) Error!void {
    const section = try file.Reader.find(bytes, kind) orelse return Error.Missing;
    var cursor: fields.Cursor = .{ .bytes = section.payload };
    var copies: Copies(@TypeOf(units)) = undefined;
    inline for (units, 0..) |unit, i| {
        copies[i] = unit.*;
        try fields.readOver(&cursor, &copies[i], .{"event_hook"});
    }
    if (!cursor.done()) return Error.BadValue;
    inline for (units, 0..) |unit, i| unit.* = copies[i];
}

/// A tuple of the pointees of a tuple of pointers.
fn Copies(comptime Units: type) type {
    const info = @typeInfo(Units).@"struct";
    var types: [info.fields.len]type = undefined;
    for (info.fields, 0..) |field, i| types[i] = @typeInfo(field.type).pointer.child;
    return std.meta.Tuple(&types);
}
