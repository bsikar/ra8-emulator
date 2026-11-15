//! Receipt persistence and validation before handing immutable ELF bytes to an app.
const std = @import("std");

const arguments = @import("arguments.zig");
const config = @import("config.zig");
const files = @import("files.zig");
const paths = @import("../workspace/path.zig");
const Project = @import("project.zig").Project;
const receipt = @import("receipt.zig");
const source = @import("../build/source.zig");

pub fn save(project: *Project, name: []const u8, bytes: []const u8) !void {
    const root = project.workspace.?.dir;
    const parent = try paths.parent(root, project.base.io, name);
    defer parent.close(project.base.io);
    parent.dir.writeFile(
        project.base.io,
        .{ .sub_path = parent.name, .data = bytes, .flags = .{ .exclusive = true } },
    ) catch |err| {
        if (err != error.PathAlreadyExists) return err;
        const prior = try files.read(project.allocator, project.base.io, root, name, 32_768);
        defer project.allocator.free(prior);
        if (!std.mem.eql(u8, prior, bytes)) return error.BuildReceiptConflict;
    };
}

pub fn verify(project: *Project, value: receipt.Receipt) ![]u8 {
    const parsed = project.parsed orelse return error.ProjectNotOpen;
    try project.checkConfig();
    if (!std.mem.eql(u8, value.config_sha256, &project.config_sha256) or
        !std.mem.eql(u8, value.target, parsed.value.target))
    {
        return error.ProjectConfigChanged;
    }

    // Bind the supplied receipt to the current configuration and selected build.
    const recipe = try config.findRecipe(parsed.value, value.recipe);
    try currentBuild(project, value);

    var name_buf: [1024]u8 = undefined;
    const original_path = try std.fmt.bufPrint(&name_buf, "{s}/result.json", .{value.directory});
    const bytes = try files.read(project.allocator, project.base.io, project.workspace.?.dir, original_path, 32_768);
    defer project.allocator.free(bytes);
    const original = try receipt.record(project.allocator, bytes);
    defer original.deinit();
    try receipt.validate(value, original.value);

    try arguments.verify(project.allocator, recipe, value, original.value, project.runner.?.compiler);

    // Bracket the ELF read with source hashes to catch edits during handoff.
    var cancel: std.atomic.Value(bool) = .init(false);
    const budget = project.budget(&cancel);
    const before = try source.revision(project.workspace.?.dir, budget);
    if (!std.mem.eql(u8, &before, value.source_sha256)) return error.SourceChanged;

    const elf = try files.read(
        project.allocator,
        project.base.io,
        project.workspace.?.dir,
        value.artifact,
        64 * 1024 * 1024,
    );
    errdefer project.allocator.free(elf);
    if (!std.mem.startsWith(u8, elf, "\x7fELF")) return error.NotElf;
    if (!std.mem.eql(u8, &files.digest(elf), value.artifact_sha256)) return error.ArtifactChanged;

    const after = try source.revision(project.workspace.?.dir, budget);
    if (!std.mem.eql(u8, &before, &after)) return error.SourceChanged;

    return elf;
}

fn currentBuild(project: *Project, value: receipt.Receipt) !void {
    if (project.latest_id != 0 and project.latest_id != value.build_id) return error.StaleBuildSelection;
    if (project.latest_id != 0) {
        const job = try project.runner.?.get(project.latest_id);
        if (!job.done.load(.acquire)) return error.BuildBusy;
        const current = try receipt.record(project.allocator, job.result[0..job.result_len]);
        defer current.deinit();
        if (!std.mem.eql(u8, value.directory, current.value.directory)) return error.StaleBuildSelection;
    }
}
