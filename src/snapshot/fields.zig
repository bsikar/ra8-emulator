//! Plain state encoded field by field for snapshots (RA8EMU-658).
//!
//! Integers, enums and packed structs go as their little-endian bits, each
//! integer widened to whole bytes; bools as one byte; arrays element by
//! element; optionals as a one-byte tag and then the value; structs field by
//! field in declaration order; tagged unions as their tag and then the
//! active payload (RA8EMU-676). A pointer, untagged union or float does not
//! compile, so nothing that is wiring rather than state can slip in.
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
        .@"enum" => try write(writer, @backingInt(value)),
        .array => for (value) |item| try write(writer, item),
        .optional => if (value) |inner| {
            try writer.writeByte(1);
            try write(writer, inner);
        } else try writer.writeByte(0),
        .@"struct" => |s| if (s.layout == .@"packed") {
            try write(writer, @as(s.backing_integer.?, @bitCast(value)));
        } else inline for (s.fields) |field| try write(writer, @field(value, field.name)),
        .@"union" => |u| {
            const Tag = u.tag_type orelse @compileError("a snapshot cannot hold untagged " ++ @typeName(T));
            try write(writer, @as(Tag, value));
            switch (value) {
                inline else => |payload| try write(writer, payload),
            }
        },
        .void => {},
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
        .@"union" => |u| {
            const Tag = u.tag_type orelse @compileError("a snapshot cannot hold untagged " ++ @typeName(T));
            const tag = try read(Tag, cursor);
            inline for (u.fields) |field| {
                if (tag == @field(Tag, field.name)) return @unionInit(T, field.name, try read(field.type, cursor));
            }
            unreachable;
        },
        .void => return {},
        else => @compileError("a snapshot cannot hold " ++ @typeName(T)),
    }
}

/// `value`'s fields in declaration order, leaving out the ones named in
/// `skip`: wiring such as a device or sink pointer that a struct of
/// otherwise plain state carries. A dotted name skips a field further down
/// (RA8EMU-681): "channels.listener" leaves out `listener` in every element
/// of `channels`.
pub fn writeExcept(writer: anytype, value: anytype, comptime skip: anytype) @TypeOf(writer).Error!void {
    inline for (@typeInfo(@TypeOf(value)).@"struct".fields) |field| {
        if (comptime named(field.name, skip)) continue;
        const inner = comptime below(field.name, skip);
        if (inner.len == 0) {
            try write(writer, @field(value, field.name));
        } else try writeInner(writer, @field(value, field.name), inner);
    }
}

fn writeInner(writer: anytype, value: anytype, comptime skip: anytype) @TypeOf(writer).Error!void {
    switch (@typeInfo(@TypeOf(value))) {
        .array => for (value) |item| try writeInner(writer, item, skip),
        .@"struct" => try writeExcept(writer, value, skip),
        else => @compileError("a skip path runs through structs and arrays only"),
    }
}

/// Reads what `writeExcept` wrote over `out`; the skipped fields keep
/// whatever `out` already held.
pub fn readOver(cursor: *Cursor, out: anytype, comptime skip: anytype) Error!void {
    inline for (@typeInfo(@TypeOf(out.*)).@"struct".fields) |field| {
        if (comptime named(field.name, skip)) continue;
        const inner = comptime below(field.name, skip);
        if (inner.len == 0) {
            @field(out.*, field.name) = try read(field.type, cursor);
        } else try readInner(cursor, &@field(out.*, field.name), inner);
    }
}

fn readInner(cursor: *Cursor, out: anytype, comptime skip: anytype) Error!void {
    switch (@typeInfo(@TypeOf(out.*))) {
        .array => for (out) |*item| try readInner(cursor, item, skip),
        .@"struct" => try readOver(cursor, out, skip),
        else => @compileError("a skip path runs through structs and arrays only"),
    }
}

fn named(comptime name: []const u8, comptime list: anytype) bool {
    inline for (list) |item| if (std.mem.eql(u8, name, item)) return true;
    return false;
}

/// The rest of each `list` entry that starts with `name` and a dot.
fn below(comptime name: []const u8, comptime list: anytype) []const []const u8 {
    var out: []const []const u8 = &.{};
    inline for (list) |item| {
        const path: []const u8 = item;
        if (path.len > name.len + 1 and std.mem.startsWith(u8, path, name) and path[name.len] == '.') {
            out = out ++ [_][]const u8{path[name.len + 1 ..]};
        }
    }
    return out;
}
