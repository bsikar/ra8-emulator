//! Versioned project data; no implicit compiler discovery or unrestricted recipes.
const std = @import("std");
const build = @import("../root.zig").build;
const paths = @import("../workspace/path.zig");
const targets = @import("../toolchain/target.zig");
const source_map = @import("map.zig");

pub const Mapping = struct { host: []const u8 = ".", client: []const u8 };
pub const Recipe = struct {
    name: []const u8,
    step: []const u8 = "",
    options: []const u8 = "[]",
    artifact: []const u8,
    timeout_ms: u32 = 300_000,
    pub fn request(self: Recipe) build.request.Request {
        return .{ .step = self.step, .options = self.options, .artifact = self.artifact, .timeout_ms = self.timeout_ms, .pin_build_file = true };
    }
};
pub const Config = struct {
    version: u32,
    root: []const u8 = ".",
    target: []const u8,
    compiler: ?[]const u8 = null,
    recipes: []const Recipe,
    source_mappings: []const Mapping = &.{},
};

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Config) {
    if (bytes.len > 65_536) return error.ProjectConfigLimit;
    const parsed = try std.json.parseFromSlice(Config, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    const value = parsed.value;
    if (value.version != 1) return error.UnsupportedProjectVersion;
    _ = try targets.find(value.target);
    var buffer: [4096]u8 = undefined;
    _ = try paths.normalize(value.root, &buffer);
    if (value.compiler) |compiler| try build.Runner.validateCompiler(compiler);
    if (value.recipes.len == 0 or value.recipes.len > 16 or value.source_mappings.len > 16) return error.ProjectConfigLimit;
    for (value.recipes, 0..) |recipe, index| {
        if (recipe.name.len == 0 or recipe.name.len > 64 or recipe.artifact.len == 0) return error.InvalidProjectRecipe;
        for (value.recipes[0..index]) |prior| if (std.mem.eql(u8, prior.name, recipe.name)) return error.DuplicateProjectRecipe;
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const checked = try build.request.parse(arena.allocator(), recipe.request());
        if (checked.artifact.len == 0) return error.InvalidProjectRecipe;
    }
    for (value.source_mappings, 0..) |mapping, index| {
        const host = try paths.normalize(mapping.host, &buffer);
        if (mapping.client.len == 0 or mapping.client.len > 2048 or std.mem.indexOfScalar(u8, mapping.client, 0) != null) return error.InvalidSourceMapping;
        if (!std.fs.path.isAbsolutePosix(mapping.client) and !(std.fs.path.isAbsoluteWindows(mapping.client) and std.fs.path.diskDesignatorWindows(mapping.client).len != 0)) return error.InvalidSourceMapping;
        var client_buffer: [4096]u8 = undefined;
        const client = try source_map.normalize(mapping.client, &client_buffer);
        if (std.mem.startsWith(u8, client, "//") and std.fs.path.diskDesignatorWindows(client).len == 0) return error.InvalidSourceMapping;
        for (value.source_mappings[0..index]) |prior| {
            var prior_host: [4096]u8 = undefined;
            var prior_client: [4096]u8 = undefined;
            const normalized_client = try source_map.normalize(prior.client, &prior_client);
            if (std.mem.eql(u8, try paths.normalize(prior.host, &prior_host), host) or (client.len == normalized_client.len and source_map.prefix(client, normalized_client))) return error.DuplicateSourceMapping;
        }
    }
    return parsed;
}

pub fn findRecipe(config: Config, name: []const u8) !Recipe {
    for (config.recipes) |item| if (std.mem.eql(u8, name, item.name)) return item;
    return error.UnknownProjectRecipe;
}
