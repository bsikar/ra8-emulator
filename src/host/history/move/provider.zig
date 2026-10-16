//! Borrowed, application-supplied native peer capability.
const std = @import("std");
const wire = @import("wire.zig");
pub const Info = struct { proxy_pid: i32, reply: wire.Reply };
pub const Observer = struct { context: *anyopaque, report: *const fn (*anyopaque, Info) anyerror!void };
pub const Provider = struct { executable: []const u8, sha256: [32]u8, observer: ?Observer = null, bounds: wire.Bounds = .{} };

pub fn check(io: std.Io, value: Provider) !void {
    if (!std.mem.eql(u8, &value.sha256, &try digest(io, value.executable))) return error.PeerDigestMismatch;
    var magic: [4]u8 = undefined;
    {
        const file = try std.Io.Dir.cwd().openFile(io, value.executable, .{ .follow_symlinks = false });
        defer file.close(io);
        if (try file.readPositionalAll(io, &magic, 0) != 4) return error.InvalidPeer;
    }
    // A peer is a PE (Windows, driven through WSL interop) or an ELF (this
    // platform). Anything else is not something this bridge spawned.
    const is_pe = std.mem.eql(u8, magic[0..2], "MZ");
    const elf = std.mem.eql(u8, &magic, "\x7fELF");
    if (!is_pe and !elf) return error.InvalidPeer;
}

/// True when the executable is a Windows PE, which only WSL interop can run
/// on this host: the bridge then converts paths for it, and its /proc
/// identity is the interop launcher's rather than its own.
pub fn pe(io: std.Io, executable: []const u8) !bool {
    var bytes: [2]u8 = undefined;
    const file = try std.Io.Dir.cwd().openFile(io, executable, .{ .follow_symlinks = false });
    defer file.close(io);
    if (try file.readPositionalAll(io, &bytes, 0) != 2) return error.InvalidPeer;
    return std.mem.eql(u8, &bytes, "MZ");
}

pub fn digest(io: std.Io, executable: []const u8) ![32]u8 {
    if (!std.fs.path.isAbsolute(executable)) return error.RelativePath;
    const file = try std.Io.Dir.cwd().openFile(io, executable, .{ .follow_symlinks = false });
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.nlink != 1) return error.OutsideRoot;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var bytes: [8192]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const count = try file.readPositionalAll(io, &bytes, offset);
        if (count == 0) break;
        hash.update(bytes[0..count]);
        offset += count;
    }
    return hash.finalResult();
}
