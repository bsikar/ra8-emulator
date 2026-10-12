//! The shell's saved board and panel choice (RA8EMU-1152): one line each
//! in the app's per-user directory, the way the layout and window files
//! save theirs. A missing or corrupt file restores nothing, so the next
//! launch opens the shipped board with its own panel.
const std = @import("std");

pub const file_name = "board";

/// A choice as fixed buffers, so a restored one owns its bytes.
pub const Choice = struct {
    board_buf: [64]u8 = undefined,
    board_len: usize = 0,
    panel_buf: [64]u8 = undefined,
    panel_len: usize = 0,

    pub fn board(self: *const Choice) []const u8 {
        return self.board_buf[0..self.board_len];
    }

    pub fn panel(self: *const Choice) []const u8 {
        return self.panel_buf[0..self.panel_len];
    }

    pub fn setBoard(self: *Choice, stem: []const u8) bool {
        return set(&self.board_buf, &self.board_len, stem);
    }

    pub fn setPanel(self: *Choice, stem: []const u8) bool {
        return set(&self.panel_buf, &self.panel_len, stem);
    }
};

pub const Store = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    /// The app's per-user directory (SDL's pref path), or null when the
    /// platform gives none: a shell without one keeps the defaults.
    dir: ?[]const u8 = null,

    /// The saved choice, or the defaults when nothing usable is saved.
    pub fn restore(self: *const Store) Choice {
        const dir = self.dir orelse return .{};
        var path: [1024]u8 = undefined;
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, joined(dir, &path), self.allocator, .limited(1024)) catch return .{};
        defer self.allocator.free(bytes);
        return parse(bytes) orelse .{};
    }

    /// Saves the choice. A failure only means the next launch starts
    /// from the defaults again.
    pub fn save(self: *const Store, choice: Choice) void {
        const dir = self.dir orelse return;
        var data: [256]u8 = undefined;
        const text = encode(choice, &data) catch return;
        var path: [1024]u8 = undefined;
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = joined(dir, &path), .data = text }) catch return;
    }
};

/// Copies a stem into a choice's fixed buffer, false when it does not fit.
fn set(buf: []u8, len: *usize, stem: []const u8) bool {
    if (stem.len > buf.len) return false;
    @memcpy(buf[0..stem.len], stem);
    len.* = stem.len;
    return true;
}

fn joined(dir: []const u8, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}/" ++ file_name, .{dir}) catch file_name;
}

fn encode(choice: Choice, buf: []u8) ![]const u8 {
    var w: usize = 0;
    if (choice.board_len > 0) try put(buf, &w, "board {s}\n", .{choice.board()});
    if (choice.panel_len > 0) try put(buf, &w, "panel {s}\n", .{choice.panel()});
    return buf[0..w];
}

fn put(buf: []u8, w: *usize, comptime fmt: []const u8, args: anytype) !void {
    const written = try std.fmt.bufPrint(buf[w.*..], fmt, args);
    w.* += written.len;
}

/// A saved file as a choice, or null when it is corrupt.
pub fn parse(bytes: []const u8) ?Choice {
    var choice = Choice{};
    var words = std.mem.tokenizeAny(u8, bytes, " \n\r");
    while (words.next()) |key| {
        const value = words.next() orelse return null;
        if (std.mem.eql(u8, key, "board")) {
            if (!choice.setBoard(value)) return null;
        } else if (std.mem.eql(u8, key, "panel")) {
            if (!choice.setPanel(value)) return null;
        } else return null;
    }
    return choice;
}
