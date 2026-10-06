//! Spawns `ra8_emulator serve --stdio` and drives it over its pipes
//! (RA8EMU-737): greet, load, run, pause, read registers, close stdin.
const std = @import("std");
const ra8 = @import("ra8");
const test_paths = @import("test_paths");
const Stdio = ra8.interfaces.rpc.stdio.Stdio;
const serve_peer = @import("serve_peer.zig");
const image_path = serve_peer.image_path;

test "serve --stdio answers a client on its pipes and exits 0 once stdin closes" {
    const gpa = std.testing.allocator;
    var child = std.process.Child.init(&.{ test_paths.emulator, "serve", "--stdio", image_path }, gpa);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    errdefer _ = child.kill() catch {};
    var pipes: Stdio = .{ .input = child.stdout.?.handle, .output = child.stdin.?.handle };
    const peer = try serve_peer.Peer.init(gpa, pipes.transport());
    defer peer.deinit();
    try peer.drive();

    child.stdin.?.close();
    child.stdin = null;
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, try child.wait());
}

test "serve without --stdio prints its usage and exits 2" {
    const result = try std.process.Child.run(.{
        .allocator = std.testing.allocator,
        .argv = &.{ test_paths.emulator, "serve", image_path },
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 2 }, result.term);
    try std.testing.expectEqualStrings(ra8.core.serve_main.usage, result.stderr);
    try std.testing.expectEqualStrings("", result.stdout);
}
