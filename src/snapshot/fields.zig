//! Plain state encoded field by field for snapshots (RA8EMU-658).
//!
//! Integers, enums and packed structs go as their little-endian bits, each
//! integer widened to whole bytes; bools as one byte; arrays element by
//! element; optionals as a one-byte tag and then the value; structs field by
//! field in declaration order. A pointer, union or float does not compile, so
//! nothing that is wiring rather than state can slip in.
const std = @import("std");

pub const Error = error{ Truncated, BadValue };

/// `T` widened to a whole number of bytes, keeping its signedness.
fn Whole(comptime T: type) type {
    const info = @typeInfo(T).int;
    return std.meta.Int(info.signedness, (info.bits + 7) / 8 * 8);
}

pub fn write(writer: anytype, value: anytype) @TypeOf(writer).Error!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .int => try writer.writeInt(Whole(T), value, .little),
        .bool => try writer.writeByte(@intFromBool(value)),
        .@"enum" => try write(writer, @intFromEnum(value)),
        .array => for (value) |item| try write(writer, item),
        .optional => if (value) |inner| {
            try writer.writeByte(1);
            try write(writer, inner);
        } else try writer.writeByte(0),
        .@"struct" => |s| if (s.layout == .@"packed") {
            try write(writer, @as(s.backing_integer.?, @bitCast(value)));
        } else inline for (s.fields) |field| try write(writer, @field(value, field.name)),
        else => @compileError("a snapshot cannot hold " ++ @typeName(T)),
    }
}

/// Where a read has got to in one section's payload.
pub const Cursor = struct {
    bytes: []const u8,
    at: usize = 0,

    fn take(self: *Cursor, len: usize) Error![]const u8 {
        if (len > self.bytes.len - self.at) return Error.Truncated;
        defer self.at += len;
        return self.bytes[self.at..][0..len];
    }

    pub fn done(self: *const Cursor) bool {
        return self.at == self.bytes.len;
    }
};

/// A value written by `write`; a bool, tag or enum outside its type, or an
/// integer too wide for its field, is BadValue.
pub fn read(comptime T: type, cursor: *Cursor) Error!T {
    switch (@typeInfo(T)) {
        .int => {
            const W = Whole(T);
            const raw = try cursor.take(@bitSizeOf(W) / 8);
            return std.math.cast(T, std.mem.readInt(W, raw[0 .. @bitSizeOf(W) / 8], .little)) orelse Error.BadValue;
        },
        .bool => return switch (try read(u8, cursor)) {
            0 => false,
            1 => true,
            else => Error.BadValue,
        },
        .@"enum" => |e| return std.meta.intToEnum(T, try read(e.tag_type, cursor)) catch Error.BadValue,
        .array => |a| {
            var out: T = undefined;
            for (&out) |*item| item.* = try read(a.child, cursor);
            return out;
        },
        .optional => |o| return switch (try read(u8, cursor)) {
            0 => null,
            1 => try read(o.child, cursor),
            else => Error.BadValue,
        },
        .@"struct" => |s| {
            if (s.layout == .@"packed") return @bitCast(try read(s.backing_integer.?, cursor));
            var out: T = undefined;
            inline for (s.fields) |field| @field(out, field.name) = try read(field.type, cursor);
            return out;
        },
        else => @compileError("a snapshot cannot hold " ++ @typeName(T)),
    }
}
