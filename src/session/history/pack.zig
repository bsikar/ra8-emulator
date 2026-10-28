//! Pure codecs for pack file framing and flate1-compressed object storage.
//!
//! Pack file layout:
//!   [Header: 32 bytes]  magic: "RA8PACK1", version: 1, pack_id: u32, reserved
//!   [Record 0: ...]     header: 28 bytes, compressed payload, crc32c: 4 bytes
//!   [Record 1: ...]     ...
//!
//! Record framing:
//!   object_id:        16 bytes (truncated Blake3-128)
//!   uncompressed_len:  4 bytes
//!   compressed_len:    4 bytes
//!   compression:       1 byte (0 = uncompressed, 1 = flate level 1)
//!   flags:             1 byte (bit 0 = page, bit 1 = blob, bit 2 = picture)
//!   reserved:          2 bytes
//!   payload:           compressed_len bytes
//!   crc32c:            4 bytes (Castagnoli CRC32-C over record header + payload)
const std = @import("std");
const ObjectId = @import("object_id.zig").ObjectId;
const Crc32c = std.hash.crc.@"CRC-32/ISCSI";

pub const magic: [8]u8 = "RA8PACK1".*;
pub const version: u32 = 1;
pub const header_len: usize = 32;
pub const record_header_len: usize = 28;
pub const trailer_len: usize = 4;
pub const record_overhead: usize = record_header_len + trailer_len;

pub const flags = struct {
    pub const page: u8 = 1 << 0;
    pub const blob: u8 = 1 << 1;
    pub const picture: u8 = 1 << 2;
};

pub const Error = error{
    BadMagic,
    BadVersion,
    TruncatedPack,
    CorruptCrc,
    ForgedIdentity,
    DecompressFailed,
    CompressFailed,
    OutOfMemory,
    WriteFailed,
    ReadFailed,
};

pub const DecodedRecord = struct {
    object_id: ObjectId,
    flags: u8,
    uncompressed_len: u32,
    compressed_len: u32,
    data: []u8,

    pub fn deinit(self: *DecodedRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        self.* = undefined;
    }
};

/// Writes the 32-byte pack header.
pub fn writeHeader(writer: anytype, pack_id: u32) !void {
    var buf: [header_len]u8 = @splat(0);
    @memcpy(buf[0..8], &magic);
    std.mem.writeInt(u32, buf[8..12], version, .little);
    std.mem.writeInt(u32, buf[12..16], pack_id, .little);
    try writer.writeAll(&buf);
}

/// Reads and validates the 32-byte pack header, returning the pack_id.
pub fn readHeader(bytes: []const u8) Error!u32 {
    if (bytes.len < header_len) return Error.TruncatedPack;
    if (!std.mem.eql(u8, bytes[0..8], &magic)) return Error.BadMagic;
    const v = std.mem.readInt(u32, bytes[8..12], .little);
    if (v != version) return Error.BadVersion;
    return std.mem.readInt(u32, bytes[12..16], .little);
}

fn compressFlate1(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, data.len / 2 + 64);
    defer out.deinit();

    const window = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(window);

    var deflater = std.compress.flate.Compress.init(&out.writer, window, .raw, .level_1) catch return Error.CompressFailed;
    deflater.writer.writeAll(data) catch return Error.CompressFailed;
    deflater.finish() catch return Error.CompressFailed;

    return out.toOwnedSlice();
}

fn decompressFlate(allocator: std.mem.Allocator, compressed: []const u8, uncompressed_len: usize) ![]u8 {
    var in_reader: std.Io.Reader = .fixed(compressed);
    const window = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(window);

    var inflater: std.compress.flate.Decompress = .init(&in_reader, .raw, window);
    const dest = try allocator.alloc(u8, uncompressed_len);
    errdefer allocator.free(dest);

    inflater.reader.readSliceAll(dest) catch return Error.DecompressFailed;
    return dest;
}

/// Encodes a single object into pack wire framing, applying flate1 compression.
/// Returns total bytes written (record_overhead + payload_len).
pub fn encodeRecord(
    allocator: std.mem.Allocator,
    writer: anytype,
    object_id: ObjectId,
    rec_flags: u8,
    data: []const u8,
) !usize {
    const compressed = compressFlate1(allocator, data) catch null;
    defer if (compressed) |c| allocator.free(c);

    const use_flate = compressed != null and compressed.?.len < data.len;
    const payload = if (use_flate) compressed.? else data;
    const compression_mode: u8 = if (use_flate) 1 else 0;

    var header_buf: [record_header_len]u8 = undefined;
    @memcpy(header_buf[0..16], &object_id.bytes);
    std.mem.writeInt(u32, header_buf[16..20], @intCast(data.len), .little);
    std.mem.writeInt(u32, header_buf[20..24], @intCast(payload.len), .little);
    header_buf[24] = compression_mode;
    header_buf[25] = rec_flags;
    header_buf[26] = 0;
    header_buf[27] = 0;

    var crc = Crc32c.init();
    crc.update(&header_buf);
    crc.update(payload);

    try writer.writeAll(&header_buf);
    try writer.writeAll(payload);
    var trailer_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &trailer_buf, crc.final(), .little);
    try writer.writeAll(&trailer_buf);

    return record_overhead + payload.len;
}

/// Decodes one record from a slice, verifying CRC, decompressing, and verifying Blake3 hash.
pub fn decodeRecordFromSlice(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) Error!struct { record: DecodedRecord, consumed: usize } {
    if (bytes.len < record_overhead) return Error.TruncatedPack;

    const obj_id = ObjectId{ .bytes = bytes[0..16].* };
    const uncompressed_len = std.mem.readInt(u32, bytes[16..20], .little);
    const compressed_len = std.mem.readInt(u32, bytes[20..24], .little);
    const compression_mode = bytes[24];
    const rec_flags = bytes[25];

    const total_len = record_overhead + @as(usize, compressed_len);
    if (bytes.len < total_len) return Error.TruncatedPack;

    const payload = bytes[record_header_len .. record_header_len + compressed_len];
    const stored_crc = std.mem.readInt(u32, bytes[record_header_len + compressed_len ..][0..4], .little);

    var crc = Crc32c.init();
    crc.update(bytes[0..record_header_len]);
    crc.update(payload);
    if (crc.final() != stored_crc) return Error.CorruptCrc;

    const data = if (compression_mode == 1)
        try decompressFlate(allocator, payload, uncompressed_len)
    else
        try allocator.dupe(u8, payload);
    errdefer allocator.free(data);

    if (data.len != uncompressed_len) return Error.DecompressFailed;

    const computed = ObjectId.compute(data);
    if (!computed.eql(obj_id)) return Error.ForgedIdentity;

    return .{
        .record = .{
            .object_id = obj_id,
            .flags = rec_flags,
            .uncompressed_len = uncompressed_len,
            .compressed_len = compressed_len,
            .data = data,
        },
        .consumed = total_len,
    };
}
