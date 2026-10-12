//! Panel profiles: the display hardware a board profile names (RA8EMU-1151).
//! A profile carries zero or one panel by reference to a file stem here, so
//! the board's display hardware lives with the rest of its composition
//! instead of in the GUI's own constants.
const std = @import("std");

pub const Kind = enum { tft, eink };
pub const Format = enum { rgb565, grayscale4 };

pub const Panel = struct {
    name: []const u8,
    kind: Kind,
    width: u16,
    height: u16,
    format: Format,
    ppi: u16,
};

pub const Error = error{BadPanel};

pub const ek_ra8d2 = @embedFile("panels/ek_ra8d2.toml");
pub const sample_480x272 = @embedFile("panels/sample_480x272.toml");
pub const sample_800x480 = @embedFile("panels/sample_800x480.toml");
pub const sample_eink = @embedFile("panels/sample_eink.toml");

/// The shipped panels, by the file stem a profile's `panel=` names.
const files = [_]struct { stem: []const u8, text: []const u8 }{
    .{ .stem = "ek_ra8d2", .text = ek_ra8d2 },
    .{ .stem = "sample_480x272", .text = sample_480x272 },
    .{ .stem = "sample_800x480", .text = sample_800x480 },
    .{ .stem = "sample_eink", .text = sample_eink },
};

/// The panel a stem names, or null when no shipped panel matches it.
pub fn byName(stem: []const u8) ?Panel {
    for (files) |one| {
        if (std.mem.eql(u8, one.stem, stem)) return parse(one.text) catch null;
    }
    return null;
}

/// Read a panel file. Every key is required and unknown or duplicate keys
/// fail closed, matching the board profile's own rules.
pub fn parse(text: []const u8) Error!Panel {
    var panel: Panel = .{
        .name = undefined,
        .kind = undefined,
        .width = undefined,
        .height = undefined,
        .format = undefined,
        .ppi = undefined,
    };
    var name: ?[]const u8 = null;
    var seen: [6]bool = @splat(false);
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = commentOff(raw);
        if (line.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return Error.BadPanel;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (key.len == 0 or value.len == 0) return Error.BadPanel;
        const slot: usize = if (std.mem.eql(u8, key, "name"))
            0
        else if (std.mem.eql(u8, key, "type"))
            1
        else if (std.mem.eql(u8, key, "format"))
            2
        else if (std.mem.eql(u8, key, "width"))
            3
        else if (std.mem.eql(u8, key, "height"))
            4
        else if (std.mem.eql(u8, key, "ppi"))
            5
        else
            return Error.BadPanel;
        if (seen[slot]) return Error.BadPanel;
        seen[slot] = true;
        switch (slot) {
            0 => name = try quoted(value),
            1 => panel.kind = std.meta.stringToEnum(Kind, try quotedOrBare(value)) orelse return Error.BadPanel,
            2 => panel.format = std.meta.stringToEnum(Format, try quotedOrBare(value)) orelse return Error.BadPanel,
            3 => panel.width = try number(u16, value),
            4 => panel.height = try number(u16, value),
            5 => panel.ppi = try number(u16, value),
            else => unreachable,
        }
    }
    panel.name = name orelse return Error.BadPanel;
    for (seen) |ok| {
        if (!ok) return Error.BadPanel;
    }
    return panel;
}

fn quotedOrBare(value: []const u8) Error![]const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') return value[1 .. value.len - 1];
    return value;
}

fn quoted(value: []const u8) Error![]const u8 {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return Error.BadPanel;
    return value[1 .. value.len - 1];
}

fn number(comptime T: type, value: []const u8) Error!T {
    return std.fmt.parseInt(T, value, 10) catch return Error.BadPanel;
}

fn commentOff(raw: []const u8) []const u8 {
    const line = std.mem.trim(u8, raw, " \t\r");
    return std.mem.trim(u8, line[0 .. std.mem.indexOfScalar(u8, line, '#') orelse line.len], " \t");
}
