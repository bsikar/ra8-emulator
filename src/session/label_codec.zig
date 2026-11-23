//! Versioned debugger metadata stored in session bundles.
const std = @import("std");

const Core = @import("event/stream.zig").Core;
const labels = @import("labels.zig");

const version = 1;
const prefix_len = 12;
const entry_len = prefix_len + labels.max_name;
const binary_cap = 1 + labels.capacity * entry_len;
const base64 = std.base64.standard;
pub const text_cap = base64.Encoder.calcSize(binary_cap);

pub fn encode(map: *const labels.Map, out: *[text_cap]u8) ?[]const u8 {
    if (map.len == 0) return null;
    var binary: [binary_cap]u8 = undefined;
    binary[0] = version;
    var end: usize = 1;
    for (map.entries[0..map.len]) |*entry| {
        put(binary[end..][0..entry_len], entry);
        end += entry_len;
    }
    return base64.Encoder.encode(out, binary[0..end]);
}

fn put(into: *[entry_len]u8, entry: *const labels.Entry) void {
    const scope = entry.key.frame;
    into[0] = @backingInt(entry.key.core);
    into[1] = if (scope) |frame| @backingInt(frame.storage) else 0xff;
    into[2] = if (scope) |frame| frame.register else 0;
    into[3] = entry.width;
    std.mem.writeInt(u32, into[4..8], entry.key.address, .little);
    std.mem.writeInt(u32, into[8..12], if (scope) |frame| frame.entry else 0, .little);
    @memcpy(into[prefix_len..], &entry.bytes);
}

pub fn decode(encoded: ?[]const u8) !labels.Map {
    var map: labels.Map = .{};
    const text = encoded orelse return map;
    const len = try base64.Decoder.calcSizeForSlice(text);
    if (len <= 1 or len > binary_cap or (len - 1) % entry_len != 0) return error.InvalidLabels;
    var binary: [binary_cap]u8 = undefined;
    try base64.Decoder.decode(binary[0..len], text);
    if (binary[0] != version) return error.InvalidLabels;
    var pos: usize = 1;
    while (pos < len) : (pos += entry_len) {
        try take(&map, binary[pos..][0..entry_len]);
    }
    return map;
}

fn take(map: *labels.Map, bytes: *const [entry_len]u8) !void {
    const core = std.enums.fromInt(Core, bytes[0]) orelse return error.InvalidLabels;
    const scope: ?labels.Scope = if (bytes[1] == 0xff) null else .{
        .entry = std.mem.readInt(u32, bytes[8..12], .little),
        .storage = std.enums.fromInt(labels.Storage, bytes[1]) orelse return error.InvalidLabels,
        .register = bytes[2],
    };
    const key: labels.Key = .{ .core = core, .address = std.mem.readInt(u32, bytes[4..8], .little), .frame = scope };
    const name = std.mem.sliceTo(bytes[prefix_len..entry_len], 0);
    if (name.len == 0 or map.at(key) != null) return error.InvalidLabels;
    try map.set(key, name, bytes[3]);
}
