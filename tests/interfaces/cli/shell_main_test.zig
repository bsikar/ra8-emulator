//! The `shell` command line (RA8EMU-770): its arguments and the host it
//! picks, the local one unless --host names a profile in the hosts file.
const std = @import("std");
const ra8 = @import("ra8");
const shell_main = ra8.core.shell_main;
const Profile = ra8.core.host_profiles.Profile;

/// No RA8_HOSTS or HOME: every lookup goes through --hosts or fails.
const empty_env: std.process.Environ.Map = .{ .array_hash_map = .empty, .allocator = std.testing.allocator };

test "an image alone runs on the local host" {
    const args = try shell_main.parse(&.{ "ra8_emulator", "shell", "app.elf" });
    try std.testing.expectEqualStrings("app.elf", args.image);
    try std.testing.expectEqual(@as(?[]const u8, null), args.host);
    try std.testing.expectEqual(Profile.local, try shell_main.pick(std.testing.allocator, std.testing.io, &empty_env, args));
}

test "--host and --hosts are kept in either order around the image" {
    const args = try shell_main.parse(&.{ "ra8_emulator", "shell", "--hosts", "/tmp/hosts", "app.elf", "--host", "lab" });
    try std.testing.expectEqualStrings("app.elf", args.image);
    try std.testing.expectEqualStrings("lab", args.host.?);
    try std.testing.expectEqualStrings("/tmp/hosts", args.hosts.?);
}

test "a missing image, a dangling flag, an unknown flag or a second image is refused" {
    const bad = [_][]const []const u8{
        &.{ "ra8_emulator", "shell" },
        &.{ "ra8_emulator", "shell", "app.elf", "--host" },
        &.{ "ra8_emulator", "shell", "--fast", "app.elf" },
        &.{ "ra8_emulator", "shell", "a.elf", "b.elf" },
        &.{ "ra8_emulator", "serve", "app.elf" },
    };
    for (bad) |argv| try std.testing.expectError(error.Usage, shell_main.parse(argv));
}

test "the host named local needs no hosts file" {
    const args = try shell_main.parse(&.{ "ra8_emulator", "shell", "--host", "local", "--hosts", "/nonexistent/hosts", "app.elf" });
    try std.testing.expectEqual(Profile.local, try shell_main.pick(std.testing.allocator, std.testing.io, &empty_env, args));
}

test "any other host comes from the hosts file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try dir.dir.writeFile(std.testing.io, .{ .sub_path = "hosts", .data = "local here\nssh lab bsikar@labvm\n" });
    const file = try dir.dir.realPathFileAlloc(std.testing.io, "hosts", gpa);
    const lab = try shell_main.pick(gpa, std.testing.io, &empty_env, .{ .image = "app.elf", .host = "lab", .hosts = file });
    try std.testing.expectEqualStrings("bsikar@labvm", lab.ssh.destination);
    try std.testing.expectEqual(Profile.local, try shell_main.pick(gpa, std.testing.io, &empty_env, .{ .image = "app.elf", .host = "here", .hosts = file }));
    try std.testing.expectError(error.UnknownHost, shell_main.pick(gpa, std.testing.io, &empty_env, .{ .image = "app.elf", .host = "gone", .hosts = file }));
}
