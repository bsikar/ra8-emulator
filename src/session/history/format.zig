//! The event log's frame on the wire: [u32 len][u16 kind][u32 crc32c][payload].
//!
//! The frozen rules a reader may assume forever:
//!
//! - `len` counts the payload's bytes only, little-endian, and may not
//!   exceed `max_len`.
//! - `kind` is little-endian; which kinds exist is `record.zig`'s table,
//!   and a reader that does not know a kind skips it unless the table
//!   calls the kind mandatory.
//! - The CRC is CRC-32C (Castagnoli) over the two little-endian kind bytes
//!   followed by the whole payload.
//!
//! A reader that cannot make sense of a frame knows which of three things
//! happened: the bytes end inside a frame (a torn tail; recovery rewinds
//! to the last whole frame), a whole frame lies about its length or fails
//! its CRC (hard error), or the frame is whole and sound (deliver it).
const std = @import("std");
const Crc32c = std.hash.crc.@"CRC-32/ISCSI";

pub const header_len: usize = 10;
/// The largest payload one frame may carry: the 16 MiB the async host
/// traffic queue caps at. A record that cannot bound itself is a bug, not
/// a growing number.
pub const max_len: usize = 16 * 1024 * 1024;

pub const Error = error{ Truncated, BadLength, BadCrc };

/// One decoded frame. `payload` borrows the bytes it was read from.
pub const Frame = struct {
    kind: u16,
    payload: []const u8,
};

/// The bytes one frame will occupy, for a writer that reserves first.
pub fn sizeOf(payload: []const u8) Error!usize {
    if (payload.len > max_len) return Error.BadLength;
    return header_len + payload.len;
}

/// Appends one frame to `writer`.
pub fn encode(writer: anytype, kind: u16, payload: []const u8) (Error || std.Io.Writer.Error)!void {
    if (payload.len > max_len) return Error.BadLength;
    var kind_bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &kind_bytes, kind, .little);
    var crc = Crc32c.init();
    crc.update(&kind_bytes);
    crc.update(payload);
    try writer.writeInt(u32, @intCast(payload.len), .little);
    try writer.writeAll(&kind_bytes);
    try writer.writeInt(u32, crc.final(), .little);
    try writer.writeAll(payload);
}

/// The CRC one frame at `kind` and `payload` carries, for a hand-encoded
/// test vector to check against.
pub fn crcOf(kind: u16, payload: []const u8) u32 {
    var kind_bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &kind_bytes, kind, .little);
    var crc = Crc32c.init();
    crc.update(&kind_bytes);
    crc.update(payload);
    return crc.final();
}

/// Decodes the frame that starts `bytes`, answering the frame (borrowing
/// the bytes) and how many bytes it consumed. Bytes that end inside the
/// header or inside the payload are a torn tail (`Truncated`); a whole
/// frame beyond the length bound or under a wrong CRC is hard.
pub fn decode(bytes: []const u8) Error!struct { frame: Frame, consumed: usize } {
    if (bytes.len < header_len) return Error.Truncated;
    const len = std.mem.readInt(u32, bytes[0..4], .little);
    if (len > max_len) return Error.BadLength;
    const kind = std.mem.readInt(u16, bytes[4..6], .little);
    const end = header_len + @as(usize, len);
    if (bytes.len < end) return Error.Truncated;
    const crc = std.mem.readInt(u32, bytes[6..10], .little);
    const payload = bytes[header_len..end];
    if (crcOf(kind, payload) != crc) return Error.BadCrc;
    return .{ .frame = .{ .kind = kind, .payload = payload }, .consumed = end };
}
