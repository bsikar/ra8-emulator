const std = @import("std");
const host = @import("ra8").host;
const Process = host.build.process.Process;
const io = std.testing.io;
const on_windows = @import("builtin").os.tag == .windows;

test "build process exit is observed without consuming output or losing ownership" {
    if (!host.build.process.supported) return error.SkipZigTest;
    const args = if (on_windows) &.{ "cmd.exe", "/d", "/c", "echo build-output" } else &.{ "/bin/sh", "-c", "printf build-output" };
    var process = try Process.spawn(io, args, .cwd());
    defer process.close() catch @panic("owned build cleanup failed");
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + 5_000_000_000;
    var bytes: [128]u8 = undefined;
    var count: usize = 0;
    while (std.Io.Clock.awake.now(io).nanoseconds < deadline) {
        if (try host.build.pipe.read(io, process.child.stdout.?, bytes[count..])) |n| count += n;
        if (try process.exited()) break;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expect(try process.exited());
    if (try host.build.pipe.read(io, process.child.stdout.?, bytes[count..])) |n| count += n;
    try std.testing.expect(std.mem.indexOf(u8, bytes[0..count], "build-output") != null);
    try std.testing.expect(process.child.id != null);
    try std.testing.expect((try process.finish()).success());
    try std.testing.expect(process.child.id == null);
}

test "build cancellation terminates its owned process tree and reaps the root" {
    if (!host.build.process.supported) return error.SkipZigTest;
    const args = if (on_windows) &.{ "cmd.exe", "/d", "/c", "ping -n 60 127.0.0.1 >NUL" } else &.{ "/bin/sh", "-c", "sleep 60" };
    var process = try Process.spawn(io, args, .cwd());
    defer process.close() catch @panic("owned build cleanup failed");
    try std.testing.expect(!try process.exited());
    try process.stopTree();
    try std.testing.expect(!(try process.finish()).success());
    try process.close();
    try std.testing.expect(process.child.id == null and process.job == null);
}

test "build process refuses ownership loss before signalling a potentially reused process id" {
    if (@import("builtin").os.tag != .macos and @import("builtin").os.tag != .linux) return error.SkipZigTest;
    var process = try Process.spawn(io, &.{ "/bin/sh", "-c", "exit 0" }, .cwd());
    defer process.close() catch @panic("lost build cleanup failed");
    const id = process.child.id.?;
    var status: c_int = 0;
    try std.testing.expectEqual(id, std.c.waitpid(id, &status, 0));
    try std.testing.expectError(error.ChildOwnershipLost, process.exited());
    try std.testing.expectError(error.ChildOwnershipLost, process.stopTree());
    try std.testing.expectError(error.ChildOwnershipLost, process.close());
    try std.testing.expect(process.child.id == null);
}
