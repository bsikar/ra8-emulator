//! Packs a Locals answer's rows (RA8EMU-805): each LocalRow as the codec
//! encodes it, one length byte before it, so both ends walk the list
//! without the codec carrying arrays.
const proto = @import("session/rpc.zig");

pub const Error = error{ Oversize, Truncated };

/// Append `row` to `out` at `at`.
pub fn put(out: []u8, at: *usize, row: proto.LocalRow) !void {
    if (at.* >= out.len) return error.Oversize;
    const body = try proto.encode(proto.LocalRow, row, out[at.* + 1 ..]);
    out[at.*] = @intCast(body.len);
    at.* += 1 + body.len;
}

/// Walks packed rows in order; slices point into the packed bytes.
pub const Reader = struct {
    rest: []const u8,

    pub fn next(self: *Reader) !?proto.LocalRow {
        if (self.rest.len == 0) return null;
        const len: usize = self.rest[0];
        if (1 + len > self.rest.len) return error.Truncated;
        defer self.rest = self.rest[1 + len ..];
        return try proto.decode(proto.LocalRow, self.rest[1..][0..len]);
    }
};
