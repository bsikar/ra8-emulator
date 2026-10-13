//! The shell's recently loaded images (RA8EMU-1153): the last ten ELFs and
//! .ra8app files, one path a line in the app's per-user directory, the way
//! the board, layout and window files save theirs. A missing or corrupt
//! file restores nothing, so the next launch starts with an empty list.
const std = @import("std");

pub const file_name = "recents";

/// The list holds the last ten (RA8EMU-1153).
pub const max: usize = 10;

/// One path's room.
pub const path_max: usize = 512;

/// The list, newest first, with each entry owning its bytes.
pub const List = struct {
    paths: [max][path_max]u8 = undefined,
    lens: [max]usize = @splat(0),
    len: usize = 0,

    pub fn path(self: *const List, at: usize) ?[]const u8 {
        if (at >= self.len) return null;
        return self.paths[at][0..self.lens[at]];
    }

    /// Puts `name` at the front, dropping a duplicate's old slot and the
    /// oldest entry past ten. False when the path does not fit.
    pub fn add(self: *List, name: []const u8) bool {
        if (name.len > path_max) return false;
        var from: ?usize = null;
        for (0..self.len) |at| {
            if (std.mem.eql(u8, self.path(at).?, name)) from = at;
        }
        const slot = from orelse if (self.len < max) self.len else max - 1;
        var i: usize = slot;
        while (i > 0) : (i -= 1) {
            self.paths[i] = self.paths[i - 1];
            self.lens[i] = self.lens[i - 1];
        }
        @memcpy(self.paths[0][0..name.len], name);
        self.lens[0] = name.len;
        if (from == null and self.len < max) self.len += 1;
        return true;
    }
};

pub const Store = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    /// The app's per-user directory (SDL's pref path), or null when the
    /// platform gives none: a shell without one keeps no history.
    dir: ?[]const u8 = null,

    /// The saved list, or an empty one when nothing usable is saved.
    pub fn restore(self: *const Store) List {
        const dir = self.dir orelse return .{};
        var path: [1024]u8 = undefined;
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, joined(dir, &path), self.allocator, .limited(max * (path_max + 1))) catch return .{};
        defer self.allocator.free(bytes);
        return parse(bytes) orelse .{};
    }

    /// Saves the list. A failure only means the next launch starts from an
    /// empty list again.
    pub fn save(self: *const Store, list: List) void {
        const dir = self.dir orelse return;
        var data: [max * (path_max + 1)]u8 = undefined;
        const text = encode(list, &data) catch return;
        var path: [1024]u8 = undefined;
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = joined(dir, &path), .data = text }) catch return;
    }
};

fn joined(dir: []const u8, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}/" ++ file_name, .{dir}) catch file_name;
}

fn encode(list: List, buf: []u8) ![]const u8 {
    var w: usize = 0;
    for (0..list.len) |at| {
        const written = try std.fmt.bufPrint(buf[w..], "{s}\n", .{list.path(at).?});
        w += written.len;
    }
    return buf[0..w];
}

/// A saved file as a list, or null when it is corrupt.
pub fn parse(bytes: []const u8) ?List {
    var list = List{};
    var rest = bytes;
    while (rest.len > 0) {
        const end = std.mem.indexOfScalar(u8, rest, '\n') orelse return null;
        const line = rest[0..end];
        rest = rest[end + 1 ..];
        if (line.len == 0 or line.len > path_max) return null;
        if (list.len >= max) return null;
        for (0..list.len) |at| if (std.mem.eql(u8, list.path(at).?, line)) return null;
        @memcpy(list.paths[list.len][0..line.len], line);
        list.lens[list.len] = line.len;
        list.len += 1;
    }
    return list;
}
