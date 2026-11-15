//! Project source availability and client/server remapping at debugger boundaries.
const std = @import("std");

const map = @import("map.zig");
const Project = @import("project.zig").Project;
const source = @import("../build/source.zig");

pub fn translate(project: *Project, name: []const u8, to_client: bool, into: []u8) ![]const u8 {
    const mapped = try location(project, name, to_client, into);
    try check(project);
    return mapped;
}

/// Batch users check the revision once after collecting all requested locations.
pub fn location(project: *Project, name: []const u8, to_client: bool, into: []u8) ![]const u8 {
    if (project.bound_source == null) return error.SourceUnavailable;
    var root_buffer: [4096]u8 = undefined;
    const root = try map.normalize(project.root_path, &root_buffer);
    var name_buffer: [4096]u8 = undefined;
    const normalized = try map.normalize(name, &name_buffer);
    var mapped_buffer: [4096]u8 = undefined;
    const mapped = try rewrite(project, root, normalized, to_client, &mapped_buffer);
    var reverse_buffer: [4096]u8 = undefined;
    const reverse = try rewrite(project, root, mapped, !to_client, &reverse_buffer);
    if (reverse.len != normalized.len or !map.prefix(normalized, reverse)) return error.AmbiguousSourceMapping;
    const host_path = if (to_client) normalized else mapped;
    if (!map.prefix(host_path, root)) return error.SourceUnavailable;
    const relative = std.mem.trimStart(u8, host_path[root.len..], "/");
    const stat = project.workspace.?.stat(relative) catch |err| return if (err == error.FileNotFound)
        error.SourceMissing
    else
        error.SourceUnavailable;
    if (stat.kind == .missing) return error.SourceMissing;
    if (stat.kind != .file) return error.SourceUnavailable;
    if (mapped.len > into.len) return error.NoSpaceLeft;
    @memcpy(into[0..mapped.len], mapped);
    return into[0..mapped.len];
}

pub fn check(project: *Project) !void {
    const expected = project.bound_source orelse return error.SourceUnavailable;
    try project.checkConfig();
    var cancel: std.atomic.Value(bool) = .init(false);
    const current = try source.revision(project.workspace.?.dir, project.budget(&cancel));
    if (!std.mem.eql(u8, &expected, &current)) return error.SourceChanged;
}

fn rewrite(project: *Project, root: []const u8, name: []const u8, to_client: bool, into: []u8) ![]const u8 {
    const mappings = project.parsed.?.value.source_mappings;
    if (mappings.len == 0) {
        if (!map.prefix(name, root)) return error.SourceUnavailable;
        if (name.len > into.len) return error.NoSpaceLeft;
        @memcpy(into[0..name.len], name);
        return into[0..name.len];
    }
    var best: usize = 0;
    var used: ?usize = null;
    for (mappings) |mapping| {
        var host_buffer: [4096]u8 = undefined;
        const host_raw = try std.fmt.bufPrint(&host_buffer, "{s}/{s}", .{ root, mapping.host });
        var normalized_host: [4096]u8 = undefined;
        const host = try map.normalize(host_raw, &normalized_host);
        var client_buffer: [4096]u8 = undefined;
        const client = try map.normalize(mapping.client, &client_buffer);
        const from = if (to_client) host else client;
        const to = if (to_client) client else host;
        if (!map.prefix(name, from) or from.len <= best) continue;
        const mapped = try map.replace(name, from, to, into);
        used = mapped.len;
        best = from.len;
    }
    return into[0 .. used orelse return error.SourceUnavailable];
}
