//! Conservative matches against the core printer's canonical operand spelling.
const std = @import("std");

const text = @import("ra8_chip").core.cpu.text.text;

pub const Memory = struct { reg: u8, offset: i64 = 0 };

pub fn number(word: []const u8) ?i64 {
    if (word.len == 0) return null;
    return std.fmt.parseInt(i64, word, 0) catch null;
}

pub fn register(word: []const u8) ?u8 {
    for (text.names, 0..) |name, index| if (std.mem.eql(u8, name, word)) return @intCast(index);
    return null;
}

pub fn usesRegister(line: []const u8, reg: u8) bool {
    if (reg >= text.names.len) return false;
    const operands = std.mem.indexOfScalar(u8, line, ' ') orelse return false;
    const end = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
    var words = std.mem.tokenizeAny(u8, line[operands + 1 .. end], " ,[]{}!");
    while (words.next()) |word| if (std.mem.eql(u8, word, text.names[reg])) return true;
    return false;
}

/// Only ordinary pre-indexed register+constant memory operands. Post-indexing,
/// writeback and register shifts have distinct semantics and are not guessed.
pub fn memory(raw: []const u8) ?Memory {
    const line = raw[0 .. std.mem.indexOfScalar(u8, raw, ';') orelse raw.len];
    const start = std.mem.indexOfScalar(u8, line, '[') orelse return null;
    const end = std.mem.indexOfScalarPos(u8, line, start, ']') orelse return null;
    if (end + 1 < line.len and (line[end + 1] == '!' or line[end + 1] == ',')) return null;
    var parts = std.mem.splitScalar(u8, line[start + 1 .. end], ',');
    const base = register(std.mem.trim(u8, parts.next().?, " ")) orelse return null;
    const offset = if (parts.next()) |word| blk: {
        const clean = std.mem.trim(u8, word, " ");
        if (clean.len < 2 or clean[0] != '#') return null;
        break :blk number(clean[1..]) orelse return null;
    } else 0;
    if (parts.next() != null) return null;
    return .{ .reg = base, .offset = offset };
}
