const std = @import("std");
const build = @import("ra8").host.build;
const io = std.testing.io;

test "build source revisions hash content and names but exclude retained outputs" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "input.zig", .data = "one" });
    var cancel: std.atomic.Value(bool) = .init(false);
    const budget: build.request.Budget = .{ .io = io, .cancel = &cancel, .deadline = std.Io.Clock.awake.now(io).nanoseconds + 5_000_000_000 };
    const before = try build.source.revision(tmp.dir, budget);
    try tmp.dir.createDir(io, ".ra8-builds", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = ".ra8-builds/old.elf", .data = "retained" });
    try std.testing.expectEqualStrings(&before, &try build.source.revision(tmp.dir, budget));
    try tmp.dir.writeFile(io, .{ .sub_path = "input.zig", .data = "two" });
    try std.testing.expect(!std.mem.eql(u8, &before, &try build.source.revision(tmp.dir, budget)));
    cancel.store(true, .release);
    try std.testing.expectError(error.BuildCanceled, build.source.revision(tmp.dir, budget));
}

test "build artifact hash requires fresh ELF bytes below its pinned output root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cancel: std.atomic.Value(bool) = .init(false);
    const budget: build.request.Budget = .{ .io = io, .cancel = &cancel, .deadline = std.Io.Clock.awake.now(io).nanoseconds + 5_000_000_000 };
    try tmp.dir.writeFile(io, .{ .sub_path = "not.elf", .data = "text" });
    try std.testing.expectError(error.NotElf, build.source.artifact(tmp.dir, "not.elf", budget));
    try tmp.dir.writeFile(io, .{ .sub_path = "fw.elf", .data = "\x7fELFpayload" });
    const hash = try build.source.artifact(tmp.dir, "fw.elf", budget);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("\x7fELFpayload", &digest, .{});
    try std.testing.expectEqualStrings(&std.fmt.bytesToHex(digest, .lower), &hash);
}

test "build provenance refuses input links instead of claiming external source coverage" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "real.zig", .data = "source" });
    tmp.dir.symLink(io, "real.zig", "alias.zig", .{}) catch |err| {
        if (@import("builtin").os.tag == .windows and err == error.PermissionDenied) return error.SkipZigTest;
        return err;
    };
    var cancel: std.atomic.Value(bool) = .init(false);
    const budget: build.request.Budget = .{ .io = io, .cancel = &cancel, .deadline = std.Io.Clock.awake.now(io).nanoseconds + 5_000_000_000 };
    try std.testing.expectError(error.UnsupportedSourceEntry, build.source.revision(tmp.dir, budget));
}
