//! Starting `serve --stdio` for a host profile (RA8EMU-196). A local
//! profile runs this emulator. An ssh profile runs the remote's, after
//! copying the image into the remote cache under its SHA-256, which is
//! skipped when the remote already holds that file.
const std = @import("std");
const profiles = @import("host_profiles.zig");

/// Largest image ctl copies to a remote.
const max_image = 64 * 1024 * 1024;

/// The argv that starts `serve --stdio` for the image at `image_path` on
/// `profile`. Memory comes from `allocator`, which ctl runs as an arena.
pub fn serveArgv(allocator: std.mem.Allocator, profile: profiles.Profile, image_path: []const u8) ![]const []const u8 {
    switch (profile) {
        .local => {
            const exe = try std.fs.selfExePathAlloc(allocator);
            return allocator.dupe([]const u8, &.{ exe, "serve", "--stdio", image_path });
        },
        .ssh => |ssh| {
            const bytes = std.fs.cwd().readFileAlloc(allocator, image_path, max_image) catch return error.ImageUnreadable;
            const remote = try cachePath(allocator, ssh.cache, bytes);
            try ensureCopied(allocator, ssh, remote, bytes);
            const line = try std.fmt.allocPrint(allocator, "{s} serve --stdio {s}", .{ try quote(allocator, ssh.emulator), try quote(allocator, remote) });
            return allocator.dupe([]const u8, &.{ ssh.program, "-T", ssh.destination, line });
        },
    }
}

/// `cache/<sha256 of bytes>.elf`.
pub fn cachePath(allocator: std.mem.Allocator, cache: []const u8, bytes: []const u8) ![]const u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.allocPrint(allocator, "{s}/{s}.elf", .{ cache, std.fmt.fmtSliceHexLower(&digest) });
}

/// Copy `bytes` to `remote` unless a `test -f` there says it is present.
/// ssh exits 255 for its own failures, which is reported as unreachable.
fn ensureCopied(allocator: std.mem.Allocator, ssh: profiles.Ssh, remote: []const u8, bytes: []const u8) !void {
    const file = try quote(allocator, remote);
    const probe = try std.fmt.allocPrint(allocator, "test -f {s}", .{file});
    const held = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ ssh.program, "-T", ssh.destination, probe } });
    switch (held.term) {
        .Exited => |code| switch (code) {
            0 => return,
            1 => {},
            else => return error.HostUnreachable,
        },
        else => return error.HostUnreachable,
    }
    const dir = try quote(allocator, ssh.cache);
    const store = try std.fmt.allocPrint(allocator, "mkdir -p {s} && cat > {s}.part && mv {s}.part {s}", .{ dir, file, file, file });
    var child = std.process.Child.init(&.{ ssh.program, "-T", ssh.destination, store }, allocator);
    child.stdin_behavior = .Pipe;
    try child.spawn();
    child.stdin.?.writeAll(bytes) catch {};
    child.stdin.?.close();
    child.stdin = null;
    if (!exitedClean(try child.wait())) return error.CopyFailed;
}

fn exitedClean(term: std.process.Child.Term) bool {
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

/// `text` single-quoted for the remote shell.
pub fn quote(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).init(allocator);
    try out.append('\'');
    for (text) |c| {
        if (c == '\'') try out.appendSlice("'\\''") else try out.append(c);
    }
    try out.append('\'');
    return out.toOwnedSlice();
}
