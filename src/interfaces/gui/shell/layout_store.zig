//! The shell's saved pane layout (RA8EMU-958): which tabs, split or decked,
//! restored on launch. One text file in the app's per-user directory,
//! depth-first: a leaf line holds its kind and core, a split its axis and
//! ratio, a deck its active child and count. A missing or corrupt file is
//! the default layout, not a crash.
const std = @import("std");
const pane_layout = @import("../ui/pane_layout.zig");

pub const file_name = "layout";
/// No saved tree nests deeper than this; anything else is a corrupt save.
const max_depth = 8;

pub const Store = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    /// The app's per-user directory (SDL's pref path), or null when the
    /// platform gives none: a shell without one keeps its own layout.
    dir: ?[]const u8 = null,

    /// Replaces `layout` with the saved tree; keeps it whole when nothing
    /// usable is saved.
    pub fn restore(self: *const Store, layout: *pane_layout.Layout) void {
        const bytes = self.read() orelse return;
        defer self.allocator.free(bytes);
        const parsed = parse(bytes, self.allocator) catch return;
        layout.deinit();
        layout.* = parsed;
    }

    /// Saves the tree. A failure only means the next launch starts from
    /// the default again.
    pub fn save(self: *const Store, layout: *const pane_layout.Layout) void {
        const dir = self.dir orelse return;
        var data: [4096]u8 = undefined;
        const text = encode(layout, &data) catch return;
        var path: [1024]u8 = undefined;
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = joined(dir, &path), .data = text }) catch return;
    }

    fn read(self: *const Store) ?[]u8 {
        const dir = self.dir orelse return null;
        var path: [1024]u8 = undefined;
        return std.Io.Dir.cwd().readFileAlloc(self.io, joined(dir, &path), self.allocator, .limited(4096)) catch null;
    }
};

fn joined(dir: []const u8, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}/" ++ file_name, .{dir}) catch file_name;
}

/// The tree as the file's text.
pub fn encode(layout: *const pane_layout.Layout, buf: []u8) ![]const u8 {
    var w: usize = 0;
    try encodeNode(layout, layout.root, buf, &w, 0);
    return buf[0..w];
}

fn encodeNode(layout: *const pane_layout.Layout, index: pane_layout.Index, buf: []u8, w: *usize, depth: u8) !void {
    if (depth > max_depth) return error.Corrupt;
    switch (layout.nodes.items[index].body) {
        .leaf => |pane| try put(buf, w, "leaf {s} {s}\n", .{ @tagName(pane.kind), @tagName(pane.core) }),
        .split => |split| {
            try put(buf, w, "split {s} {d}\n", .{ @tagName(split.axis), split.ratio });
            try encodeNode(layout, split.first, buf, w, depth + 1);
            try encodeNode(layout, split.second, buf, w, depth + 1);
        },
        .deck => |deck| {
            try put(buf, w, "deck {d} {d}\n", .{ deck.active, deck.count });
            for (deck.children[0..deck.count]) |child| try encodeNode(layout, child, buf, w, depth + 1);
        },
        .free => return error.Corrupt,
    }
}

fn put(buf: []u8, w: *usize, comptime fmt: []const u8, args: anytype) !void {
    const written = try std.fmt.bufPrint(buf[w.*..], fmt, args);
    w.* += written.len;
}

/// A saved tree as a fresh layout.
pub fn parse(bytes: []const u8, allocator: std.mem.Allocator) !pane_layout.Layout {
    var parser = Parser{ .bytes = bytes };
    var layout = pane_layout.Layout{ .allocator = allocator };
    errdefer layout.deinit();
    layout.root = try parseNode(&parser, &layout, 0);
    if (!parser.done()) return error.Corrupt;
    return layout;
}

fn parseNode(parser: *Parser, layout: *pane_layout.Layout, depth: u8) !pane_layout.Index {
    if (depth > max_depth) return error.Corrupt;
    const head = parser.word() orelse return error.Corrupt;
    if (std.mem.eql(u8, head, "leaf")) {
        const kind = std.meta.stringToEnum(pane_layout.Kind, parser.word() orelse return error.Corrupt) orelse return error.Corrupt;
        const core = std.meta.stringToEnum(pane_layout.Core, parser.word() orelse return error.Corrupt) orelse return error.Corrupt;
        return layout.add(.{ .body = .{ .leaf = .{ .kind = kind, .core = core } } });
    }
    if (std.mem.eql(u8, head, "split")) {
        const axis = std.meta.stringToEnum(pane_layout.Axis, parser.word() orelse return error.Corrupt) orelse return error.Corrupt;
        const ratio = std.fmt.parseFloat(f32, parser.word() orelse return error.Corrupt) catch return error.Corrupt;
        if (!(ratio > 0 and ratio < 1)) return error.Corrupt;
        const first = try parseNode(parser, layout, depth + 1);
        const second = try parseNode(parser, layout, depth + 1);
        const index = try layout.add(.{ .body = .{ .split = .{ .axis = axis, .ratio = ratio, .first = first, .second = second } } });
        layout.nodes.items[first].parent = index;
        layout.nodes.items[second].parent = index;
        return index;
    }
    if (std.mem.eql(u8, head, "deck")) {
        const active = try parser.count();
        const held = try parser.count();
        if (held == 0 or held > pane_layout.max_deck or active >= held) return error.Corrupt;
        var value = pane_layout.Deck{ .count = held, .active = active };
        var at: u8 = 0;
        while (at < held) : (at += 1) value.children[at] = try parseNode(parser, layout, depth + 1);
        const index = try layout.add(.{ .body = .{ .deck = value } });
        for (value.children[0..held]) |child| layout.nodes.items[child].parent = index;
        return index;
    }
    return error.Corrupt;
}

const Parser = struct {
    bytes: []const u8,
    at: usize = 0,

    fn word(self: *Parser) ?[]const u8 {
        while (self.at < self.bytes.len and std.ascii.isWhitespace(self.bytes[self.at])) self.at += 1;
        const began = self.at;
        while (self.at < self.bytes.len and !std.ascii.isWhitespace(self.bytes[self.at])) self.at += 1;
        return if (self.at == began) null else self.bytes[began..self.at];
    }

    fn done(self: *const Parser) bool {
        var probe = self.*;
        return probe.word() == null;
    }

    fn count(self: *Parser) !u8 {
        const found = self.word() orelse return error.Corrupt;
        return std.fmt.parseInt(u8, found, 10) catch error.Corrupt;
    }
};
