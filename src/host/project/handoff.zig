//! Receipt persistence and validation before handing immutable ELF bytes to an app.
const std = @import("std");
const Project = @import("project.zig").Project;
const receipt = @import("receipt.zig");
const config = @import("config.zig");
const files = @import("files.zig");
const source = @import("../build/source.zig");
const paths = @import("../workspace/path.zig");
const request = @import("../build/request.zig");

pub fn save(project: *Project, name: []const u8, bytes: []const u8) !void {
    const root = project.workspace.?.dir;
    const parent = try paths.parent(root, project.base.io, name);
    defer parent.close(project.base.io);
    parent.dir.writeFile(project.base.io, .{ .sub_path = parent.name, .data = bytes, .flags = .{ .exclusive = true } }) catch |err| {
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

    const recipe = try config.findRecipe(parsed.value, value.recipe);
    if (project.latest_id != 0 and project.latest_id != value.build_id) return error.StaleBuildSelection;
    if (project.latest_id != 0) {
        const job = try project.runner.?.get(project.latest_id);
        if (!job.done.load(.acquire)) return error.BuildBusy;
        const current = try receipt.record(project.allocator, job.result[0..job.result_len]);
        defer current.deinit();
        if (!std.mem.eql(u8, value.directory, current.value.directory)) return error.StaleBuildSelection;
    }

    var name_buf: [1024]u8 = undefined;
    const original_path = try std.fmt.bufPrint(&name_buf, "{s}/result.json", .{value.directory});
    const bytes = try files.read(project.allocator, project.base.io, project.workspace.?.dir, original_path, 32_768);
    defer project.allocator.free(bytes);
    const original = try receipt.record(project.allocator, bytes);
    defer original.deinit();
    try receipt.validate(value, original.value);

    var arena: std.heap.ArenaAllocator = .init(project.allocator);
    defer arena.deinit();
    const selected = try request.parse(arena.allocator(), recipe.request());
    if (!std.mem.eql(u8, selected.step, original.value.step) or selected.options.len != original.value.options.len) return error.InvalidBuildReceipt;
    for (selected.options, original.value.options) |asked, built| {
        if (!std.mem.eql(u8, asked, built)) return error.InvalidBuildReceipt;
    }

    const prefix = try std.fmt.bufPrint(&name_buf, "{s}/out", .{value.directory});
    const arguments = original.value.argv;
    const expected_args = [_][]const u8{ value.compiler, "build", "-j1", "--color=off", "--prefix", prefix, "--build-file", "build.zig" };
    const has_step: usize = @intFromBool(selected.step.len != 0);
    if (arguments.len != expected_args.len + has_step + selected.options.len) return error.InvalidBuildReceipt;
    for (expected_args, arguments[0..expected_args.len]) |asked, built| {
        if (!std.mem.eql(u8, asked, built)) return error.InvalidBuildReceipt;
    }

    if (has_step != 0 and !std.mem.eql(u8, arguments[expected_args.len], selected.step)) return error.InvalidBuildReceipt;
    for (selected.options, arguments[expected_args.len + has_step ..]) |asked, built| {
        if (!std.mem.eql(u8, asked, built)) return error.InvalidBuildReceipt;
    }

    const expected = try std.fmt.bufPrint(&name_buf, "{s}/out/{s}", .{ value.directory, selected.artifact });
    if (!std.mem.eql(u8, expected, value.artifact) or
        !std.mem.eql(u8, value.compiler, project.runner.?.compiler))
    {
        return error.InvalidBuildReceipt;
    }

    var cancel: std.atomic.Value(bool) = .init(false);
    const budget = project.budget(&cancel);
    const before = try source.revision(project.workspace.?.dir, budget);
    if (!std.mem.eql(u8, &before, value.source_sha256)) return error.SourceChanged;

    const elf = try files.read(project.allocator, project.base.io, project.workspace.?.dir, value.artifact, 64 * 1024 * 1024);
    errdefer project.allocator.free(elf);
    if (!std.mem.startsWith(u8, elf, "\x7fELF")) return error.NotElf;
    if (!std.mem.eql(u8, &files.digest(elf), value.artifact_sha256)) return error.ArtifactChanged;

    const after = try source.revision(project.workspace.?.dir, budget);
    if (!std.mem.eql(u8, &before, &after)) return error.SourceChanged;

    return elf;
}
