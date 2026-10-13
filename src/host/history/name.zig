//! Names under a history root. Every name the host is handed is checked to
//! be one plain path component before it reaches a file call, so nothing
//! can name a file outside its session directory.
const std = @import("std");
const layout = @import("layout.zig");

pub const id_len = 32;
/// A session's name: 128 random bits as lower-case hex.
pub const Id = [id_len]u8;

pub const limits = struct {
    pub const component = 96;
    /// `trash-` or `.creating` around an id.
    pub const entry = id_len + 16;
};

pub const Kind = enum { session, creating, trash, pointer, lease, native_move, reserved, foreign };
pub const Entry = struct { kind: Kind, id: []const u8 = "" };

/// `text` when it is a single safe path component: letters, digits, `_`,
/// `-` and `.`, not starting with `.` or `-`, not ending with `.`, and not
/// a Windows device name.
pub fn component(text: []const u8) error{BadName}![]const u8 {
    if (text.len == 0 or text.len > limits.component) return error.BadName;
    for (text) |byte| switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.' => {},
        else => return error.BadName,
    };
    if (text[0] == '.' or text[0] == '-' or text[text.len - 1] == '.') return error.BadName;
    if (device(text[0 .. std.mem.indexOfScalar(u8, text, '.') orelse text.len])) return error.BadName;
    return text;
}

fn device(stem: []const u8) bool {
    for ([_][]const u8{ "con", "prn", "aux", "nul" }) |word| {
        if (std.ascii.eqlIgnoreCase(stem, word)) return true;
    }
    if (stem.len != 4 or stem[3] < '1' or stem[3] > '9') return false;
    return std.ascii.eqlIgnoreCase(stem[0..3], "com") or std.ascii.eqlIgnoreCase(stem[0..3], "lpt");
}

pub fn isId(text: []const u8) bool {
    if (text.len != id_len) return false;
    for (text) |byte| switch (byte) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

/// `text` as a session id.
pub fn id(text: []const u8) error{BadName}!Id {
    if (!isId(text)) return error.BadName;
    return text[0..id_len].*;
}

pub fn newId(io: std.Io) Id {
    var raw: [id_len / 2]u8 = undefined;
    io.random(&raw);
    return std.fmt.bytesToHex(raw, .lower);
}

/// What a root's entry called `text` is.
pub fn classify(text: []const u8) Entry {
    if (isId(text)) return .{ .kind = .session, .id = text };
    if (cut(text, "", layout.affix.creating)) |inner| return .{ .kind = .creating, .id = inner };
    if (cut(text, "", layout.affix.pointer)) |inner| return .{ .kind = .pointer, .id = inner };
    if (cut(text, "", layout.affix.lease)) |inner| return .{ .kind = .lease, .id = inner };
    if (cut(text, "", ".native-move")) |inner| return .{ .kind = .native_move, .id = inner };
    if (cut(text, layout.affix.trash, "")) |inner| return .{ .kind = .trash, .id = inner };
    for ([_][]const u8{ layout.root.marker, layout.root.gate, layout.root.tag }) |own| {
        if (std.mem.eql(u8, text, own)) return .{ .kind = .reserved };
    }
    return .{ .kind = .foreign };
}

fn cut(text: []const u8, prefix: []const u8, suffix: []const u8) ?[]const u8 {
    if (text.len != prefix.len + id_len + suffix.len) return null;
    if (!std.mem.startsWith(u8, text, prefix) or !std.mem.endsWith(u8, text, suffix)) return null;
    const inner = text[prefix.len..][0..id_len];
    return if (isId(inner)) inner else null;
}

pub const Buffer = [limits.entry]u8;

pub fn creating(buffer: *Buffer, of: []const u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{s}" ++ layout.affix.creating, .{of}) catch unreachable;
}

pub fn trash(buffer: *Buffer, of: []const u8) []const u8 {
    return std.fmt.bufPrint(buffer, layout.affix.trash ++ "{s}", .{of}) catch unreachable;
}

pub fn pointer(buffer: *Buffer, of: []const u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{s}" ++ layout.affix.pointer, .{of}) catch unreachable;
}

pub fn lease(buffer: *Buffer, of: []const u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{s}" ++ layout.affix.lease, .{of}) catch unreachable;
}
