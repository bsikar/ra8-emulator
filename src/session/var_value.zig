//! Typed scalar parsing and little-endian encoding for variable writes.
const std = @import("std");
const vars = @import("dwarf/dwarf.zig").vars;

pub const ScalarKind = enum {
    signed,
    unsigned,
    float,
    boolean,
    untyped,
};

pub const EncodeError = error{
    InvalidValue,
    Overflow,
    UnsupportedWidth,
};

/// Map DWARF type info to the scalar encoding category used for input parsing.
pub fn inferKind(info: vars.TypeInfo) error{NonScalar}!ScalarKind {
    if (!info.is_scalar and info.encoding == .unknown) {
        if (info.size > 0 or info.name.len > 0) return error.NonScalar;
        return .untyped;
    }
    return switch (info.encoding) {
        .signed => .signed,
        .unsigned, .address, .utf => .unsigned,
        .float => .float,
        .boolean => .boolean,
        .unknown => .untyped,
    };
}

/// Encode `raw_value` as `width` little-endian bytes according to `kind`.
pub fn encodeValue(raw_value: []const u8, width: u32, kind: ScalarKind, out: *[8]u8) EncodeError![]const u8 {
    const val = std.mem.trim(u8, raw_value, " \t\r\n");
    if (val.len == 0) return error.InvalidValue;
    if (width != 1 and width != 2 and width != 4 and width != 8) return error.UnsupportedWidth;

    switch (kind) {
        .signed => return encodeSigned(val, width, out),
        .unsigned => return encodeUnsigned(val, width, out),
        .untyped => return encodeUntyped(val, width, out),
        .float => return encodeFloat(val, width, out),
        .boolean => return encodeBool(val, width, out),
    }
}

fn encodeSigned(val: []const u8, width: u32, out: *[8]u8) EncodeError![]const u8 {
    const parsed = std.fmt.parseInt(i64, val, 0) catch |err| return if (err == error.Overflow)
        error.Overflow
    else
        error.InvalidValue;
    const ok = switch (width) {
        1 => parsed >= std.math.minInt(i8) and parsed <= std.math.maxInt(i8),
        2 => parsed >= std.math.minInt(i16) and parsed <= std.math.maxInt(i16),
        4 => parsed >= std.math.minInt(i32) and parsed <= std.math.maxInt(i32),
        8 => true,
        else => unreachable,
    };
    if (!ok) return error.Overflow;
    std.mem.writeInt(i64, out, parsed, .little);
    return out[0..width];
}

fn encodeUnsigned(val: []const u8, width: u32, out: *[8]u8) EncodeError![]const u8 {
    if (val[0] == '-') return error.Overflow;
    const parsed = std.fmt.parseInt(u64, val, 0) catch |err| return if (err == error.Overflow)
        error.Overflow
    else
        error.InvalidValue;
    const limit: u64 = switch (width) {
        1 => std.math.maxInt(u8),
        2 => std.math.maxInt(u16),
        4 => std.math.maxInt(u32),
        8 => std.math.maxInt(u64),
        else => unreachable,
    };
    if (parsed > limit) return error.Overflow;
    std.mem.writeInt(u64, out, parsed, .little);
    return out[0..width];
}

fn encodeUntyped(val: []const u8, width: u32, out: *[8]u8) EncodeError![]const u8 {
    if (val[0] == '-') return encodeSigned(val, width, out);
    return encodeUnsigned(val, width, out);
}

fn encodeFloat(val: []const u8, width: u32, out: *[8]u8) EncodeError![]const u8 {
    const wants_inf = std.ascii.eqlIgnoreCase(val, "inf") or
        std.ascii.eqlIgnoreCase(val, "+inf") or
        std.ascii.eqlIgnoreCase(val, "-inf");
    switch (width) {
        4 => {
            const f = std.fmt.parseFloat(f32, val) catch return error.InvalidValue;
            if (!wants_inf and std.math.isInf(f)) return error.Overflow;
            std.mem.writeInt(u32, out[0..4], @bitCast(f), .little);
            return out[0..4];
        },
        8 => {
            const f = std.fmt.parseFloat(f64, val) catch return error.InvalidValue;
            if (!wants_inf and std.math.isInf(f)) return error.Overflow;
            std.mem.writeInt(u64, out, @bitCast(f), .little);
            return out[0..8];
        },
        else => return error.UnsupportedWidth,
    }
}

fn encodeBool(val: []const u8, width: u32, out: *[8]u8) EncodeError![]const u8 {
    @memset(out, 0);
    if (std.ascii.eqlIgnoreCase(val, "true")) {
        out[0] = 1;
        return out[0..width];
    }
    if (std.ascii.eqlIgnoreCase(val, "false")) {
        out[0] = 0;
        return out[0..width];
    }
    const parsed = std.fmt.parseInt(i64, val, 0) catch |err| return if (err == error.Overflow)
        error.Overflow
    else
        error.InvalidValue;
    if (parsed != 0 and parsed != 1) return error.Overflow;
    out[0] = @intCast(parsed);
    return out[0..width];
}
