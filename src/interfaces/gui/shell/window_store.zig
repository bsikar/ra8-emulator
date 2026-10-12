//! The shell's saved window geometry (RA8EMU-966): its size in points,
//! where it sat on the screen, and whether it was full screen, one line
//! in the app's per-user directory. A missing or corrupt file restores
//! nothing, so the next launch keeps the opener's default geometry.
const std = @import("std");
const platform = @import("../platform.zig");

pub const file_name = "window";

pub const Store = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    /// The app's per-user directory (SDL's pref path), or null when the
    /// platform gives none: a shell without one keeps its own geometry.
    dir: ?[]const u8 = null,

    /// The saved geometry, or null when nothing usable is saved.
    pub fn restore(self: *const Store) ?platform.WindowState {
        const dir = self.dir orelse return null;
        var path: [1024]u8 = undefined;
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, joined(dir, &path), self.allocator, .limited(1024)) catch return null;
        defer self.allocator.free(bytes);
        return parse(bytes);
    }

    /// Saves the geometry. A failure only means the next launch starts
    /// from the default again.
    pub fn save(self: *const Store, state: platform.WindowState) void {
        const dir = self.dir orelse return;
        var data: [256]u8 = undefined;
        const text = encode(state, &data) catch return;
        var path: [1024]u8 = undefined;
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = joined(dir, &path), .data = text }) catch return;
    }
};

fn joined(dir: []const u8, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}/" ++ file_name, .{dir}) catch file_name;
}

/// The geometry right now, as the platform reports it.
pub fn capture(window: platform.Platform) platform.WindowState {
    const size = window.size();
    const pos = window.position();
    return .{
        .width = size.width,
        .height = size.height,
        .x = if (pos) |p| p.x else null,
        .y = if (pos) |p| p.y else null,
        .fullscreen = window.fullscreen(),
    };
}

fn encode(state: platform.WindowState, buf: []u8) ![]const u8 {
    var w: usize = 0;
    try put(buf, &w, "size {d} {d}", .{ state.width, state.height });
    if (state.x != null and state.y != null) try put(buf, &w, " pos {d} {d}", .{ state.x.?, state.y.? });
    try put(buf, &w, " full {d}\n", .{@intFromBool(state.fullscreen)});
    return buf[0..w];
}

fn put(buf: []u8, w: *usize, comptime fmt: []const u8, args: anytype) !void {
    const written = try std.fmt.bufPrint(buf[w.*..], fmt, args);
    w.* += written.len;
}

/// A saved line as geometry, or null when it is missing or corrupt.
pub fn parse(bytes: []const u8) ?platform.WindowState {
    var it = Tokenizer{ .bytes = bytes };
    if (!wordIs(&it, "size")) return null;
    var state = platform.WindowState{
        .width = it.uint() orelse return null,
        .height = it.uint() orelse return null,
    };
    if (it.peekIs("pos")) {
        _ = it.word();
        state.x = it.int(i32) orelse return null;
        state.y = it.int(i32) orelse return null;
    }
    if (!wordIs(&it, "full")) return null;
    const flag = it.int(u8) orelse return null;
    if (flag > 1) return null;
    state.fullscreen = flag == 1;
    // Nothing else may follow: a longer file is a corrupt save.
    if (it.word() != null) return null;
    if (state.width == 0 or state.height == 0) return null;
    return state;
}

fn wordIs(it: *Tokenizer, expected: []const u8) bool {
    const got = it.word() orelse return false;
    return std.mem.eql(u8, got, expected);
}

const Tokenizer = struct {
    bytes: []const u8,

    /// The next space- or newline-separated word, or null.
    /// Whether the next word is `expected`, without taking it.
    fn peekIs(self: *Tokenizer, expected: []const u8) bool {
        var probe = self.*;
        const got = probe.word() orelse return false;
        return std.mem.eql(u8, got, expected);
    }

    fn word(self: *Tokenizer) ?[]const u8 {
        while (self.bytes.len > 0 and (self.bytes[0] == ' ' or self.bytes[0] == '\n' or self.bytes[0] == '\r')) self.bytes = self.bytes[1..];
        const end = std.mem.indexOfAny(u8, self.bytes, " \n\r") orelse self.bytes.len;
        const got = self.bytes[0..end];
        self.bytes = self.bytes[end..];
        return if (got.len == 0) null else got;
    }

    fn uint(self: *Tokenizer) ?u32 {
        return std.fmt.parseInt(u32, self.word() orelse return null, 10) catch null;
    }

    fn int(self: *Tokenizer, comptime T: type) ?T {
        return std.fmt.parseInt(T, self.word() orelse return null, 10) catch null;
    }
};
