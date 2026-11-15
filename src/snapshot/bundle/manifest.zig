//! Small, versioned description of the opaque state and recording payloads.
const std = @import("std");

const file = @import("../file.zig");

pub const Image = struct {
    name: []const u8,
    /// Existing history image identity: the first 16 bytes of BLAKE3.
    identity: [16]u8,
    size: u64,
};

pub const Metadata = struct {
    board: []const u8,
    elf0: Image,
    elf1: ?Image = null,
};

pub const Elf = struct {
    name: []const u8,
    /// Lowercase hexadecimal, avoiding JSON string treatment of raw identity bytes.
    identity: [32]u8,
    size: u64,

    fn from(image: Image) Elf {
        return .{ .name = image.name, .identity = std.fmt.bytesToHex(image.identity, .lower), .size = image.size };
    }
};

pub const Manifest = struct {
    format: []const u8 = "ra8-session-bundle",
    version: u32 = 1,
    snapshot_version: u32 = file.version,
    board: []const u8,
    elf0: Elf,
    elf1: ?Elf,
    recording: bool,
};

pub fn encode(buffer: []u8, metadata: Metadata, recording: bool) ![]const u8 {
    try text(metadata.board);
    try text(metadata.elf0.name);
    if (metadata.elf1) |image| {
        try text(image.name);
    }

    var out = std.Io.Writer.fixed(buffer);
    try std.json.Stringify.value(Manifest{
        .board = metadata.board,
        .elf0 = Elf.from(metadata.elf0),
        .elf1 = if (metadata.elf1) |image| Elf.from(image) else null,
        .recording = recording,
    }, .{}, &out);
    return out.buffered();
}

fn text(value: []const u8) !void {
    if (value.len == 0 or value.len > 256) return error.InvalidMetadata;
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidMetadata;
    if (std.mem.findScalar(u8, value, 0) != null) return error.InvalidMetadata;
}
