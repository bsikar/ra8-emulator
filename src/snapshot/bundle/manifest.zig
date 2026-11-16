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
    format: []const u8,
    version: u32,
    snapshot_version: u32,
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
        .format = "ra8-session-bundle",
        .version = 1,
        .snapshot_version = file.version,
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

/// Required fields have no parse defaults: a truncated manifest cannot masquerade as version 1.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Manifest) {
    if (bytes.len > 8192) return error.TooLarge;
    const parsed = try std.json.parseFromSlice(Manifest, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    const value = parsed.value;
    if (!std.mem.eql(u8, value.format, "ra8-session-bundle")) return error.BadFormat;
    if (value.version != 1) return error.BadBundleVersion;
    if (value.snapshot_version != file.version) return error.BadSnapshotVersion;
    try text(value.board);
    try imageCheck(value.elf0);
    if (value.elf1) |image| {
        try imageCheck(image);
    }
    return parsed;
}

fn imageCheck(image: Elf) !void {
    try text(image.name);
    for (image.identity) |c| {
        if (!std.ascii.isDigit(c) and (c < 'a' or c > 'f')) return error.BadIdentity;
    }
}
