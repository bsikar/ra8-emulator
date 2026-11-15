//! Bounded DAP Content-Length framing, independent of packet boundaries.
const std = @import("std");
pub const max_body = 64 * 1024;
pub const Decoder = struct {
    header: [1024]u8 = undefined,
    used: usize = 0,
    length: ?usize = null,
    body: [max_body]u8 = undefined,
    taken: usize = 0,

    /// A message borrows body until the next push. Invalid frames end the connection.
    pub fn push(self: *Decoder, byte: u8) !?[]const u8 {
        if (self.length) |length| {
            self.body[self.taken] = byte;
            self.taken += 1;
            if (self.taken != length) return null;
            self.length = null;
            self.taken = 0;
            return self.body[0..length];
        }
        if (self.used == self.header.len) return error.HeaderTooLong;
        self.header[self.used] = byte;
        self.used += 1;
        const header = self.header[0..self.used];
        if (!std.mem.endsWith(u8, header, "\r\n\r\n")) return null;
        var lines = std.mem.splitSequence(u8, header[0 .. header.len - 4], "\r\n");
        var length: ?usize = null;
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadHeader;
            if (!std.ascii.eqlIgnoreCase(line[0..colon], "Content-Length")) continue;
            if (length != null) return error.DuplicateLength;
            const text = std.mem.trim(u8, line[colon + 1 ..], " \t");
            if (text.len == 0) return error.BadLength;
            for (text) |digit| if (!std.ascii.isDigit(digit)) return error.BadLength;
            length = std.fmt.parseInt(usize, text, 10) catch return error.BadLength;
        }
        const size = length orelse return error.MissingLength;
        if (size == 0 or size > max_body) return error.BadLength;
        self.used = 0;
        self.length = size;
        return null;
    }
};

pub fn write(out: *std.Io.Writer, json: []const u8) !void {
    try out.print("Content-Length: {d}\r\n\r\n{s}", .{ json.len, json });
}
