//! Validate imported packs and indexes before the ordinary store can repair them.
const std = @import("std");

const history = @import("ra8_host").history;
const session = @import("ra8_session");
const Stage = @import("stage.zig").Stage;
const validation = @import("validation.zig");

pub fn check(gpa: std.mem.Allocator, stage: *Stage, expanded_limit: u64) !void {
    var context: Check = .{ .gpa = gpa, .stage = stage, .remaining = expanded_limit };
    const store = history.storage.Store.from(&stage.session);
    try store.vtable.list(store.context, .objects, .{ .context = &context, .visit = Check.visit });
}

const Check = struct {
    gpa: std.mem.Allocator,
    stage: *Stage,
    remaining: u64,

    fn visit(context: *anyopaque, name: []const u8, size: u64) anyerror!void {
        _ = size;
        const self: *Check = @ptrCast(@alignCast(context));
        if (!std.mem.startsWith(u8, name, "pack-")) return;
        if (std.mem.endsWith(u8, name, ".idx")) {
            const id = try packId(name, ".idx");
            var buffer: [32]u8 = undefined;
            const store = history.storage.Store.from(&self.stage.session);
            const pack_name = try std.fmt.bufPrint(&buffer, "pack-{d:0>6}.pack", .{id});
            const byte = try store.vtable.open(store.context, .objects, pack_name, .read);
            byte.vtable.close(byte.context);
            return;
        }
        const id = try packId(name, ".pack");
        const bytes = try self.stage.read(self.gpa, .objects, name, validation.max_file);
        defer self.gpa.free(bytes);
        if (try session.history_pack.readHeader(bytes) != id) return error.CorruptPack;
        var buffer: [32]u8 = undefined;
        const index_name = try std.fmt.bufPrint(&buffer, "pack-{d:0>6}.idx", .{id});
        const index_bytes = try self.stage.read(self.gpa, .objects, index_name, validation.max_file);
        defer self.gpa.free(index_bytes);
        var index = try session.history_pack_index.decode(self.gpa, index_bytes);
        defer index.deinit(self.gpa);
        if (index.pack_id != id) return error.CorruptIndex;
        var accounted: u64 = session.history_pack.header_len;
        for (index.entries) |entry| {
            try self.record(bytes, entry);
            accounted += session.history_pack.record_overhead + @as(u64, entry.compressed_len);
        }
        if (accounted != bytes.len) return error.CorruptPack;
    }

    fn record(self: *Check, bytes: []const u8, entry: session.history_pack_index.Entry) !void {
        const start = entry.pack_offset;
        const length = session.history_pack.record_overhead + @as(u64, entry.compressed_len);
        if (start < session.history_pack.header_len or start > bytes.len) return error.CorruptIndex;
        if (length > bytes.len - start) return error.TruncatedPack;
        const raw = bytes[@intCast(start)..][0..@intCast(length)];
        const expanded = std.mem.readInt(u32, raw[16..20], .little);
        if (expanded > validation.max_file or expanded > self.remaining) return error.TooLarge;
        self.remaining -= expanded;
        const got = try session.history_pack.decodeRecordFromSlice(self.gpa, raw);
        var value = got.record;
        defer value.deinit(self.gpa);
        if (got.consumed != raw.len or !value.object_id.eql(entry.object_id)) return error.CorruptIndex;
        if (entry.compressed_len != value.compressed_len or
            entry.uncompressed_len != value.uncompressed_len or
            entry.xxh3_prefilter != entry.object_id.prefilter()) return error.CorruptIndex;
    }
};

fn packId(name: []const u8, suffix: []const u8) !u32 {
    if (!std.mem.endsWith(u8, name, suffix)) return error.BadPackName;
    const end = name.len - suffix.len;
    if (end <= 5) return error.BadPackName;
    const id = std.fmt.parseInt(u32, name[5..end], 10) catch return error.BadPackName;
    if (id == std.math.maxInt(u32)) return error.TooManyPacks;
    var buffer: [32]u8 = undefined;
    const expected = try std.fmt.bufPrint(&buffer, "pack-{d:0>6}{s}", .{ id, suffix });
    if (!std.mem.eql(u8, name, expected)) return error.BadPackName;
    return id;
}
