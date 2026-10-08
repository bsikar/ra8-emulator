//! `ctl --host NAME --image ELF` over a local profile and over an ssh
//! profile (RA8EMU-196). The ssh profile runs a stand-in for ssh that drops
//! the destination and runs the remote command here, so the copy-by-hash
//! and the remote `serve --stdio` are exercised without a network.
const std = @import("std");
const test_paths = @import("test_paths");
const uart_image = @import("ctl_run.zig").uart_image;

const fake_ssh =
    \\#!/bin/sh
    \\echo "$@" >> "$(dirname "$0")/ssh.log"
    \\shift 2
    \\exec sh -c "$*"
    \\
;

const Rig = struct {
    tmp: std.testing.TmpDir,
    root: []const u8,
    hosts: []const u8,

    fn init(gpa: std.mem.Allocator) !Rig {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
        errdefer gpa.free(root);
        const script = try tmp.dir.createFile(std.testing.io, "fake_ssh", .{ .permissions = .executable_file });
        try script.writeStreamingAll(std.testing.io, fake_ssh);
        script.close(std.testing.io);
        const lines = try std.fmt.allocPrint(gpa, "local here\nssh lab labvm emulator={s} cache={s}/cache ssh={s}/fake_ssh\n", .{ test_paths.emulator, root, root });
        defer gpa.free(lines);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "hosts", .data = lines });
        return .{ .tmp = tmp, .root = root, .hosts = try std.fs.path.join(gpa, &.{ root, "hosts" }) };
    }

    fn deinit(self: *Rig, gpa: std.mem.Allocator) void {
        gpa.free(self.hosts);
        gpa.free(self.root);
        self.tmp.cleanup();
    }

    /// Run one ctl command on `host` and return its stdout; exit 0 is required.
    fn ctl(self: *const Rig, gpa: std.mem.Allocator, host: []const u8, words: []const []const u8) ![]u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ test_paths.emulator, "ctl", "--host", host, "--hosts", self.hosts, "--image", uart_image, "--json" });
        try argv.appendSlice(gpa, words);
        const result = try std.process.run(gpa, std.testing.io, .{ .argv = argv.items });
        defer gpa.free(result.stderr);
        errdefer gpa.free(result.stdout);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
        return result.stdout;
    }

    fn count(self: *const Rig, gpa: std.mem.Allocator, needle: []const u8) !usize {
        const log = try self.tmp.dir.readFileAlloc(std.testing.io, "ssh.log", gpa, .limited(64 * 1024));
        defer gpa.free(log);
        return std.mem.count(u8, log, needle);
    }
};

test "a run over an ssh profile matches the same run over a local profile" {
    const gpa = std.testing.allocator;
    var rig = try Rig.init(gpa);
    defer rig.deinit(gpa);
    const local = try rig.ctl(gpa, "here", &.{ "run", "--budget", "20000" });
    defer gpa.free(local);
    const remote = try rig.ctl(gpa, "lab", &.{ "run", "--budget", "20000" });
    defer gpa.free(remote);
    try std.testing.expect(std.mem.indexOf(u8, local, "\"stopped\"") != null);
    try std.testing.expectEqualStrings(local, remote);
}

test "the image is copied to the remote cache once and reused after that" {
    const gpa = std.testing.allocator;
    var rig = try Rig.init(gpa);
    defer rig.deinit(gpa);
    for (0..2) |_| gpa.free(try rig.ctl(gpa, "lab", &.{ "regs", "pc" }));
    try std.testing.expectEqual(@as(usize, 2), try rig.count(gpa, "test -f"));
    try std.testing.expectEqual(@as(usize, 1), try rig.count(gpa, "mkdir -p"));
    try std.testing.expectEqual(@as(usize, 2), try rig.count(gpa, "serve --stdio"));
    var cache = try rig.tmp.dir.openDir(std.testing.io, "cache", .{ .iterate = true });
    defer cache.close(std.testing.io);
    var it = cache.iterate();
    const entry = (try it.next(std.testing.io)).?;
    try std.testing.expect(std.mem.endsWith(u8, entry.name, ".elf"));
    try std.testing.expectEqual(@as(?std.Io.Dir.Entry, null), try it.next(std.testing.io));
}

test "an unknown profile names the hosts file problem and exits 1" {
    const gpa = std.testing.allocator;
    var rig = try Rig.init(gpa);
    defer rig.deinit(gpa);
    const result = try std.process.run(gpa, std.testing.io, .{ .argv = &.{ test_paths.emulator, "ctl", "--host", "nowhere", "--hosts", rig.hosts, "--image", uart_image, "--json", "pause" } });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, result.term);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "\"error\":\"UnknownHost\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "\"message\":") != null);
}
