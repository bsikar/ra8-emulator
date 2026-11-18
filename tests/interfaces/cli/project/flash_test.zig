const std = @import("std");

const cli = @import("cli_app");
const test_paths = @import("test_paths");

const flash = cli.project.flash;

test "project flash CLI parses flags and rejects target profile mismatch before starting build" {
    const ok = try flash.parse(&.{
        "ra8_emulator", "project",   "flash",     "/ws",
        "project.json", "debug",     "--connect", "tcp:127.0.0.1:9000",
        "--target",     "win-bench", "jlink-a",   "fpb-ra8e1",
        "7",            "-",         "--zig",     test_paths.compiler,
        "--reset",      "--uart",
    });
    try std.testing.expectEqualStrings("fpb-ra8e1", ok.selection.board_id);
    try std.testing.expect(ok.reset and ok.uart);

    try std.testing.expectError(error.BadArguments, flash.parse(&.{
        "ra8_emulator", "project", "flash", "/ws", "project.json", "debug",
    }));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try tmp.dir.createDirPath(io, "fw");
    try tmp.dir.writeFile(io, .{ .sub_path = "fw/build.zig", .data = "invalid zig that must never execute\n" });
    try tmp.dir.writeFile(io, .{
        .sub_path = "project.json",
        .data = "{\"version\":1,\"root\":\"fw\",\"target\":\"fpb-ra8e1\",\"recipes\":[{\"name\":\"debug\",\"artifact\":\"bin/fw.elf\"}]}",
    });
    const root_path = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root_path);

    const mismatch = try flash.parse(&.{
        "ra8_emulator", "project",   "flash",     root_path,
        "project.json", "debug",     "--connect", "tcp:127.0.0.1:9",
        "--target",     "win-bench", "jlink-b",   "fpb-ra4t1",
        "3",            "-",         "--zig",     test_paths.compiler,
    });
    try std.testing.expectError(error.TargetProfileMismatch, flash.execute(gpa, io, mismatch));
}
