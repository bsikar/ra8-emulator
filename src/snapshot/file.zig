//! The snapshot file (RA8EMU-561, RA8EMU-659): a magic, a format version,
//! then sections. Each section is a kind and a length ahead of its bytes,
//! so a later slice (CPU state, peripheral state) adds a kind without
//! breaking a reader that does not know it: an unknown kind is skipped. An
//! unknown version is refused, since its sections may mean something else.
//!
//! Every number is little-endian.
const std = @import("std");

pub const magic = "RA8SNAP\x00".*;
pub const version: u32 = 1;

pub const Error = error{ BadMagic, BadVersion, Truncated };

/// What a section holds. Values are part of the format and never reused.
pub const Kind = enum(u32) {
    memory = 1,
    /// One core's architectural state (RA8EMU-658).
    cpu = 2,
    _,
};

pub const Section = struct {
    kind: Kind,
    payload: []const u8,
};

pub fn writeHeader(writer: anytype) !void {
    try writer.writeAll(&magic);
    try writer.writeInt(u32, version, .little);
}

/// The section's kind and length; its `len` payload bytes follow.
pub fn writeSectionHeader(writer: anytype, kind: Kind, len: u64) !void {
    try writer.writeInt(u32, @intFromEnum(kind), .little);
    try writer.writeInt(u64, len, .little);
}

/// Walks the sections of a whole snapshot held in memory.
pub const Reader = struct {
    bytes: []const u8,
    at: usize,

    /// Checks the magic and version.
    pub fn open(bytes: []const u8) Error!Reader {
        if (bytes.len < magic.len) return Error.Truncated;
        if (!std.mem.eql(u8, bytes[0..magic.len], &magic)) return Error.BadMagic;
        var self: Reader = .{ .bytes = bytes, .at = magic.len };
        if (try self.int(u32) != version) return Error.BadVersion;
        return self;
    }

    /// The next section, or null at the end.
    pub fn next(self: *Reader) Error!?Section {
        if (self.at == self.bytes.len) return null;
        const kind: Kind = @enumFromInt(try self.int(u32));
        const len = try self.int(u64);
        if (len > self.bytes.len - self.at) return Error.Truncated;
        const payload = self.bytes[self.at..][0..@intCast(len)];
        self.at += payload.len;
        return .{ .kind = kind, .payload = payload };
    }

    /// The first section of `kind`, or null when there is none.
    pub fn find(bytes: []const u8, kind: Kind) Error!?Section {
        var reader = try open(bytes);
        while (try reader.next()) |section| {
            if (section.kind == kind) return section;
        }
        return null;
    }

    fn int(self: *Reader, comptime T: type) Error!T {
        const size = @sizeOf(T);
        if (self.bytes.len - self.at < size) return Error.Truncated;
        const value = std.mem.readInt(T, self.bytes[self.at..][0..size], .little);
        self.at += size;
        return value;
    }
};
