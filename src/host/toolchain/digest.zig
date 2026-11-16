//! Hash pinned archives and ordinary installed files with bounded memory.
const std = @import("std");

pub const Sha = std.crypto.hash.sha2.Sha256;

pub fn file(io: std.Io, opened: std.Io.File, maximum: u64) ![64]u8 {
    const size = (try opened.stat(io)).size;
    if (size > maximum) return error.FileTooLarge;
    var buffer: [65536]u8 = undefined;
    var hash = Sha.init(.{});
    var offset: u64 = 0;
    while (offset < size) {
        const part = buffer[0..@intCast(@min(buffer.len, size - offset))];
        if (try opened.readPositionalAll(io, part, offset) != part.len) return error.UnexpectedEndOfStream;
        hash.update(part);
        offset += part.len;
    }
    if ((try opened.stat(io)).size != size) return error.FileChanged;
    return std.fmt.bytesToHex(hash.finalResult(), .lower);
}

pub fn bytes(data: []const u8) [64]u8 {
    var value: [32]u8 = undefined;
    Sha.hash(data, &value, .{});
    return std.fmt.bytesToHex(value, .lower);
}
