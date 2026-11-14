const std = @import("std");
const Fixture = @import("fixture.zig").Fixture;

const io = std.testing.io;

test "project close and reopen never retain a build or bound source selection" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try std.testing.expectError(error.ProjectAlreadyOpen, f.project.open("project.json"));
    try std.testing.expectError(error.UnknownBuild, f.project.prepare(42));
    f.project.close();
    try std.testing.expect(f.project.runner == null and f.project.workspace == null and f.project.bound_source == null);
    try std.testing.expectError(error.ProjectNotOpen, f.project.start("debug"));
    try f.project.open("project.json");
    try std.testing.expectEqual(@as(u64, 0), f.project.latest_id);
}

test "project refuses stale source and changed ELF even when a successful old record survives" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.receipt();
    const bytes = try f.project.load(Fixture.receipt_path);
    std.testing.allocator.free(bytes);
    try f.tmp.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "two" });
    try std.testing.expectError(error.SourceChanged, f.project.load(Fixture.receipt_path));
    try f.tmp.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "one" });
    try f.tmp.dir.writeFile(io, .{ .sub_path = Fixture.artifact, .data = "\x7fELFchanged" });
    try std.testing.expectError(error.ArtifactChanged, f.project.load(Fixture.receipt_path));
}

test "a failed current project build refuses a retained older artifact and never prepares a fallback" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.receipt();
    const id = try f.project.start("debug");
    const job = try f.project.runner.?.get(id);
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + 5_000_000_000;
    while (!job.done.load(.acquire)) {
        if (std.Io.Clock.awake.now(io).nanoseconds >= deadline) return error.BuildDidNotFinish;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expectError(error.BuildNotSuccessful, f.project.prepare(id));
    try std.testing.expectError(error.StaleBuildSelection, f.project.load(Fixture.receipt_path));
    try std.testing.expectEqual(.file, (try f.tmp.dir.statFile(io, Fixture.artifact, .{})).kind);
}

test "project builds require a regular build file at the selected root instead of searching its parents" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.tmp.dir.deleteFile(io, "build.zig");
    try std.testing.expectError(error.ProjectBuildFileRequired, f.project.start("debug"));
    try std.testing.expect(f.project.runner.?.job == null);
}
