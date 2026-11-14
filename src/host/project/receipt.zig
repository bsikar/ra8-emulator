//! Immutable handoff data bound to the original successful backend build record.
const std = @import("std");

pub const Receipt = struct {
    version: u32 = 1,
    config_sha256: []const u8,
    recipe: []const u8,
    target: []const u8,
    build_id: u64,
    directory: []const u8,
    artifact: []const u8,
    artifact_sha256: []const u8,
    source_sha256: []const u8,
    compiler: []const u8,
    compiler_version: []const u8,
};
pub const Record = struct {
    id: u64,
    state: []const u8,
    cleanup: []const u8,
    directory: []const u8,
    artifact: []const u8,
    artifact_sha256: []const u8,
    source_sha256: []const u8,
    compiler: []const u8,
    compiler_version: []const u8,
    step: []const u8,
    options: []const []const u8,
    argv: []const []const u8,
};

pub fn record(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Record) {
    const parsed = try std.json.parseFromSlice(Record, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    errdefer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.state, "succeeded") or !std.mem.eql(u8, parsed.value.cleanup, "complete")) return error.BuildNotSuccessful;
    return parsed;
}

pub fn validate(value: Receipt, original: Record) !void {
    if (value.version != 1 or value.build_id == 0 or value.build_id != original.id) return error.InvalidBuildReceipt;
    if (value.directory.len != 44 or !std.mem.startsWith(u8, value.directory, ".ra8-builds/")) return error.InvalidBuildReceipt;
    for (value.directory[12..]) |c| if (!std.ascii.isHex(c)) return error.InvalidBuildReceipt;
    if (value.artifact_sha256.len != 64 or value.source_sha256.len != 64) return error.InvalidBuildReceipt;
    inline for (.{ "directory", "artifact", "artifact_sha256", "source_sha256", "compiler", "compiler_version" }) |field| {
        if (!std.mem.eql(u8, @field(value, field), @field(original, field))) return error.InvalidBuildReceipt;
    }
}
