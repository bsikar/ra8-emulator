//! The shell's device list (RA8EMU-792): the parts fitted on each endpoint,
//! as the session lists them over the wire (list_parts, RA8EMU-791). Once the
//! link is connected it asks once; the reply's `MODEL@ENDPOINT` lines are kept
//! and drawn one row each, the part's name then its endpoint, muted.
const std = @import("std");
const proto = @import("../interfaces/rpc/session_rpc.zig");
const session_link = @import("session_link.zig");
const draw_list = @import("draw_list.zig");
const font = @import("font.zig");
const shell_frame = @import("shell_frame.zig");

/// Rows sit this far apart, a glyph and a gap.
pub const row_h: i32 = font.glyph_h + 3;
/// The endpoint column starts past the longest catalog name (max17048).
pub const name_cells: usize = 9;

pub const Devices = struct {
    text: [proto.PartList.max_len.text]u8 = undefined,
    len: usize = 0,
    asked: ?u32 = null,
    answered: bool = false,
    refused: bool = false,

    /// Ask for cpu0's parts, once, after the session greets.
    pub fn attach(self: *Devices, link: *session_link.Link) void {
        if (self.asked != null or link.state != .connected) return;
        self.asked = link.send(proto.CoreOnly, .list_parts, .{ .core = .cpu0 }) catch return;
    }

    /// Keep the listing from the response to our ask; ignore the rest.
    pub fn observe(self: *Devices, arrival: session_link.Arrival) void {
        const response = switch (arrival) {
            .response => |response| response,
            .event => return,
        };
        if (self.answered or self.asked != response.id) return;
        self.answered = true;
        const body = switch (response.result) {
            .ok => |body| body,
            .err => return self.refuse(),
        };
        const list = proto.decode(proto.PartList, body) catch return self.refuse();
        const kept = @min(list.text.len, self.text.len);
        @memcpy(self.text[0..kept], list.text[0..kept]);
        self.len = kept;
    }

    fn refuse(self: *Devices) void {
        self.refused = true;
    }

    /// The listing's lines, one fitted part each.
    pub fn lines(self: *const Devices) std.mem.TokenIterator(u8, .scalar) {
        return std.mem.tokenizeScalar(u8, self.text[0..self.len], '\n');
    }

    /// The note the leaf shows instead of rows, or null when it has rows.
    pub fn note(self: *const Devices) ?[]const u8 {
        if (!self.answered) return null;
        if (self.refused) return "the session would not list its parts";
        if (self.len == 0) return "no parts fitted";
        return null;
    }
};

/// A listing line split into the part's name and its endpoint.
pub fn split(line: []const u8) struct { name: []const u8, at: []const u8 } {
    const mark = std.mem.indexOfScalar(u8, line, '@') orelse return .{ .name = "", .at = line };
    return .{ .name = line[0..mark], .at = line[mark + 1 ..] };
}

/// Draw one row per fitted part inside `body`, as many as fit.
pub fn draw(list: *draw_list.DrawList, body: draw_list.Rect, devices: *const Devices) !void {
    const room = body.w - 2 * shell_frame.pad;
    if (room <= 0) return;
    const x = body.x + shell_frame.pad;
    const column: i32 = @intCast(font.textWidth(name_cells));
    var y = body.y + shell_frame.pad;
    var rows = devices.lines();
    while (rows.next()) |line| : (y += row_h) {
        if (y + font.glyph_h > body.y + body.h) return;
        const part = split(line);
        try font.draw(list, x, y, font.fit(part.name, @intCast(room)), shell_frame.ink);
        if (room <= column) continue;
        try font.draw(list, x + column, y, font.fit(part.at, @intCast(room - column)), shell_frame.muted);
    }
}
