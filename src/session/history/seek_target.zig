//! The seek target language: one string any front end hands the transport,
//! parsed into a typed target the seek engine resolves.
//!
//! The transport's `Seek` command carries its target as text, so the GUI's
//! time bar, the CLI and the RPC adapter all speak one grammar. The parser
//! never allocates and never consults the history's live state: it decides
//! which form the text names and turns it into numbers. Everything that
//! needs the recorded history to answer (which checkpoint is nearest, what
//! span a percent is a fraction of, whether a named branch is the current
//! line) is the seek engine's job, not this file's.
//!
//! Forms:
//!   12.402s, +500ms, -2s, 500ns   absolute or relative virtual time
//!   25%, +10%, -5%                a fraction of the recorded span
//!   3:cpu1:4:polled               round:phase:offset:gap
//!   2:3:cpu0:1:retired            branch:round:phase:offset:gap
//!   frame 12, prev, next          checkpoint pictures
//!   iter 7                        the 7th round boundary
//!   bm main_loop                  a named bookmark
//!   arrival 2 0x08001abc          the 2nd arrival at a point
//!
//! A bare number is refused: every time names its unit, so no form is
//! ambiguous with another. A bookmark may contain colons or percent signs;
//! the keyword forms are recognized before the bare forms are tried.
//! Fraction digits a unit cannot represent are refused unless they are all
//! zero, so 1.0ns parses and 1.5ns does not; nothing is rounded.
const std = @import("std");
const position_mod = @import("position.zig");

pub const Error = error{BadValue};

pub const Position = position_mod.Position;
pub const Phase = position_mod.Phase;
pub const Gap = position_mod.Gap;

/// A virtual time. Absolute is nanoseconds since the line's root and is
/// never negative; relative is signed nanoseconds from the current position.
pub const Time = struct {
    relative: bool,
    ns: i64,
};

/// A fraction of the recorded span, in basis points (1% is 100). Absolute
/// stays within [0, 10000]; relative is signed and unbounded here.
pub const Percent = struct {
    relative: bool,
    basis_points: i64,
};

/// A checkpoint picture: an absolute index, or the one before or after the
/// cursor.
pub const Frame = union(enum) {
    index: u64,
    prev,
    next,
};

/// The Nth round boundary. One, not zero, is the first.
pub const Iteration = struct {
    n: u64,
};

/// A named bookmark. The name borrows the parsed text; the engine copies a
/// bookmark it keeps.
pub const Bookmark = struct {
    name: []const u8,
};

/// The Nth arrival at a point. The point's identity (which armed breakpoint
/// or watch the address means) is the transport's to say, not this file's.
pub const Point = struct {
    address: u32,
    /// Which arrival, counting from one.
    nth: u64,
};

/// An exact place on a line. `branch_named` is true when the text named a
/// branch; a named branch other than the session's current line resolves to
/// OtherLine until branch support lands.
pub const PositionTarget = struct {
    position: Position,
    branch_named: bool,
};

pub const Target = union(enum) {
    time: Time,
    percent: Percent,
    position: PositionTarget,
    frame: Frame,
    iteration: Iteration,
    bookmark: Bookmark,
    point: Point,
};

/// Parses one target string. Refuses anything it cannot name exactly.
pub fn parse(text: []const u8) Error!Target {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return Error.BadValue;
    if (std.mem.indexOfScalar(u8, trimmed, ' ')) |sp| {
        return keyword(trimmed[0..sp], std.mem.trim(u8, trimmed[sp + 1 ..], " \t"));
    }
    if (std.mem.eql(u8, trimmed, "prev")) return .{ .frame = .prev };
    if (std.mem.eql(u8, trimmed, "next")) return .{ .frame = .next };
    if (std.mem.indexOfScalar(u8, trimmed, ':') != null) return parsePosition(trimmed);
    if (trimmed[trimmed.len - 1] == '%') return parsePercent(trimmed);
    return parseTime(trimmed);
}

fn keyword(word: []const u8, rest: []const u8) Error!Target {
    if (std.mem.eql(u8, word, "frame")) {
        return .{ .frame = .{ .index = try unsigned(u64, rest) } };
    }
    if (std.mem.eql(u8, word, "iter")) {
        const n = try unsigned(u64, rest);
        if (n == 0) return Error.BadValue;
        return .{ .iteration = .{ .n = n } };
    }
    if (std.mem.eql(u8, word, "bm")) {
        if (rest.len == 0) return Error.BadValue;
        return .{ .bookmark = .{ .name = rest } };
    }
    if (std.mem.eql(u8, word, "arrival")) return parseArrival(rest);
    return Error.BadValue;
}

fn parseArrival(rest: []const u8) Error!Target {
    const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse return Error.BadValue;
    const nth = try unsigned(u64, rest[0..sp]);
    if (nth == 0) return Error.BadValue;
    const addr_text = std.mem.trim(u8, rest[sp + 1 ..], " \t");
    if (addr_text.len == 0 or std.mem.indexOfScalar(u8, addr_text, ' ') != null) return Error.BadValue;
    const address: u32 = if (isHex(addr_text))
        std.fmt.parseInt(u32, addr_text[2..], 16) catch return Error.BadValue
    else
        try unsigned(u32, addr_text);
    return .{ .point = .{ .address = address, .nth = nth } };
}

fn isHex(text: []const u8) bool {
    if (text.len < 3) return false;
    return text[0] == '0' and (text[1] == 'x' or text[1] == 'X');
}

fn parsePosition(text: []const u8) Error!Target {
    var fields: [5][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, text, ':');
    while (it.next()) |field| {
        if (count == fields.len) return Error.BadValue;
        fields[count] = field;
        count += 1;
    }
    var first: usize = 0;
    var branch: u32 = 0;
    var branch_named = false;
    if (count == fields.len) {
        branch = try unsigned(u32, fields[0]);
        branch_named = true;
        first = 1;
    } else if (count != 4) return Error.BadValue;
    return .{ .position = .{
        .position = .{
            .branch = branch,
            .r = try unsigned(u64, fields[first]),
            .phase = std.meta.stringToEnum(Phase, fields[first + 1]) orelse return Error.BadValue,
            .o = try unsigned(u32, fields[first + 2]),
            .gap = std.meta.stringToEnum(Gap, fields[first + 3]) orelse return Error.BadValue,
        },
        .branch_named = branch_named,
    } };
}

fn parsePercent(text: []const u8) Error!Target {
    const num = try parseNumber(text[0 .. text.len - 1]);
    const total = try value(num, 2);
    if (!num.relative and (total < 0 or total > 10_000)) return Error.BadValue;
    return .{ .percent = .{ .relative = num.relative, .basis_points = try narrow(total) } };
}

fn parseTime(text: []const u8) Error!Target {
    var digits_end: usize = 0;
    if (text.len > 0 and (text[0] == '+' or text[0] == '-')) digits_end = 1;
    while (digits_end < text.len and (std.ascii.isDigit(text[digits_end]) or text[digits_end] == '.')) digits_end += 1;
    const exp = unitExp(text[digits_end..]) orelse return Error.BadValue;
    const num = try parseNumber(text[0..digits_end]);
    return .{ .time = .{ .relative = num.relative, .ns = try narrow(try value(num, exp)) } };
}

/// The unit's log10 scale in nanoseconds: seconds are 1e9, milliseconds
/// 1e6, microseconds 1e3, nanoseconds 1.
fn unitExp(unit: []const u8) ?u6 {
    if (std.mem.eql(u8, unit, "s")) return 9;
    if (std.mem.eql(u8, unit, "ms")) return 6;
    if (std.mem.eql(u8, unit, "us")) return 3;
    if (std.mem.eql(u8, unit, "ns")) return 0;
    return null;
}

fn narrow(total: i128) Error!i64 {
    if (total > std.math.maxInt(i64) or total < std.math.minInt(i64)) return Error.BadValue;
    return @intCast(total);
}

const Number = struct {
    relative: bool,
    negative: bool,
    int: u64,
    frac: []const u8,
};

/// Splits a signed decimal with an optional fraction into its parts. The
/// unit suffix is already off; `text` is only digits, dots and the sign.
fn parseNumber(text: []const u8) Error!Number {
    var body = text;
    var num = Number{ .relative = false, .negative = false, .int = 0, .frac = "" };
    if (body.len > 0 and (body[0] == '+' or body[0] == '-')) {
        num.relative = true;
        num.negative = body[0] == '-';
        body = body[1..];
    }
    const dot = std.mem.indexOfScalar(u8, body, '.');
    const int_part = if (dot) |d| body[0..d] else body;
    if (dot) |d| {
        num.frac = body[d + 1 ..];
        if (num.frac.len == 0) return Error.BadValue;
        for (num.frac) |c| if (!std.ascii.isDigit(c)) return Error.BadValue;
    }
    if (int_part.len == 0 and num.frac.len == 0) return Error.BadValue;
    if (int_part.len > 0) num.int = std.fmt.parseInt(u64, int_part, 10) catch return Error.BadValue;
    return num;
}

/// The number's exact value in the unit `exp` names, as an i128 wide
/// enough to hold any i64 after the overflow check its caller applies.
/// Fraction digits past the unit's precision must all be zero.
fn value(num: Number, exp: u6) Error!i128 {
    var total: i128 = @as(i128, @intCast(num.int)) * @as(i128, @intCast(pow10(exp)));
    if (num.frac.len > 0) {
        if (exp == 0) {
            for (num.frac) |c| if (c != '0') return Error.BadValue;
        } else if (num.frac.len > exp) {
            for (num.frac[exp..]) |c| if (c != '0') return Error.BadValue;
            total += @as(i128, @intCast(try unsigned(u64, num.frac[0..exp])));
        } else {
            const f: i128 = @intCast(try unsigned(u64, num.frac));
            const rest: u6 = exp - @as(u6, @intCast(num.frac.len));
            total += f * @as(i128, @intCast(pow10(rest)));
        }
    }
    if (num.negative) total = -total;
    return total;
}

fn pow10(n: u6) u128 {
    var out: u128 = 1;
    var left: u6 = n;
    while (left > 0) : (left -= 1) out *= 10;
    return out;
}

fn unsigned(comptime T: type, text: []const u8) Error!T {
    if (text.len == 0) return Error.BadValue;
    if (text[0] == '+' or text[0] == '-') return Error.BadValue;
    for (text) |c| if (!std.ascii.isDigit(c)) return Error.BadValue;
    return std.fmt.parseInt(T, text, 10) catch return Error.BadValue;
}
