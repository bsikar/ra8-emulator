//! Host file and confined state-file operations for `ra8_session` (ADR 0004
//! D20, RA8EMU-1175). `ra8_session` declares structural callback types in
//! `file_ops.zig`; applications and host tests fill them from here so nothing
//! inside `src/session/` touches `std.Io.Dir`, `std.Io.File`, or `std.posix`.
const std = @import("std");
const builtin = @import("builtin");

/// Validate that `path` is a bare file name: non-empty, no `/` or `\`, no drive
/// colon `:`, no NUL byte, and neither `.` nor `..`.
pub fn bareName(path: []const u8) !void {
    if (path.len == 0) return error.BadStatePath;
    if (std.mem.indexOfAny(u8, path, "/\\:\x00") != null) return error.BadStatePath;
    if (std.mem.eql(u8, path, ".") or std.mem.eql(u8, path, "..")) return error.BadStatePath;
}

/// Create `dir_path` under `root` and restrict permissions to owner-only on
/// Linux (RA8EMU-1175). Skips mode bits on Windows.
pub fn harden(io: std.Io, root: std.Io.Dir, dir_path: []const u8) !void {
    try root.createDirPath(io, dir_path);
    if (builtin.os.tag != .linux) return;
    const path = std.posix.toPosixPath(dir_path) catch return;
    _ = std.posix.system.fchmodat(std.posix.AT.FDCWD, &path, 0o700, 0);
}

fn dirOf(context: ?*anyopaque) std.Io.Dir {
    if (context) |ptr| {
        const dir: *const std.Io.Dir = @ptrCast(@alignCast(ptr));
        return dir.*;
    }
    return std.Io.Dir.cwd();
}

pub fn readAlloc(
    context: ?*anyopaque,
    io: std.Io,
    path: []const u8,
    allocator: std.mem.Allocator,
    max_bytes: usize,
) anyerror![]u8 {
    return dirOf(context).readFileAlloc(io, path, allocator, .limited(max_bytes));
}

pub fn writeStream(
    context: ?*anyopaque,
    io: std.Io,
    path: []const u8,
    stream_context: *anyopaque,
    write_stream: *const fn (*anyopaque, *std.Io.Writer) anyerror!void,
) anyerror!void {
    var out = try dirOf(context).createFile(io, path, .{});
    defer out.close(io);
    var buffer: [4096]u8 = undefined;
    var file_writer = out.writer(io, &buffer);
    try write_stream(stream_context, &file_writer.interface);
    try file_writer.interface.flush();
}

pub fn saveState(
    context: ?*anyopaque,
    io: std.Io,
    dir: ?[]const u8,
    name: []const u8,
    stream_context: *anyopaque,
    write_stream: *const fn (*anyopaque, *std.Io.Writer) anyerror!void,
) anyerror!void {
    try bareName(name);
    const root = dirOf(context);
    const gpa = std.heap.page_allocator;
    const full = if (dir) |d| try std.fs.path.join(gpa, &.{ d, name }) else try gpa.dupe(u8, name);
    defer gpa.free(full);
    if (dir) |d| try harden(io, root, d);
    const temp = try std.mem.concat(gpa, u8, &.{ full, ".tmp" });
    defer gpa.free(temp);
    var committed = false;
    defer if (!committed) root.deleteFile(io, temp) catch {};
    {
        var out = try root.createFile(io, temp, .{});
        defer out.close(io);
        var buffer: [4096]u8 = undefined;
        var file_writer = out.writer(io, &buffer);
        try write_stream(stream_context, &file_writer.interface);
        try file_writer.interface.flush();
    }
    try root.rename(temp, root, full, io);
    committed = true;
}

pub fn restoreState(
    context: ?*anyopaque,
    io: std.Io,
    allocator: std.mem.Allocator,
    dir: ?[]const u8,
    name: []const u8,
    max_bytes: usize,
) anyerror![]u8 {
    try bareName(name);
    const root = dirOf(context);
    const full = if (dir) |d| try std.fs.path.join(allocator, &.{ d, name }) else try allocator.dupe(u8, name);
    defer allocator.free(full);
    return root.readFileAlloc(io, full, allocator, .limited(max_bytes));
}

pub fn reader(comptime R: type) R {
    return .{ .context = null, .readFn = readAlloc };
}

pub fn readerInDir(comptime R: type, dir: *const std.Io.Dir) R {
    return .{ .context = @constCast(dir), .readFn = readAlloc };
}

pub fn writer(comptime W: type) W {
    return .{ .context = null, .writeFn = writeStream };
}

pub fn writerInDir(comptime W: type, dir: *const std.Io.Dir) W {
    return .{ .context = @constCast(dir), .writeFn = writeStream };
}

pub fn stateStore(comptime S: type) S {
    return .{ .context = null, .saveFn = saveState, .restoreFn = restoreState };
}

pub fn stateStoreInDir(comptime S: type, dir: *const std.Io.Dir) S {
    return .{ .context = @constCast(dir), .saveFn = saveState, .restoreFn = restoreState };
}

pub fn cwd(comptime Ops: type) Ops {
    return .{
        .reader = .{ .context = null, .readFn = readAlloc },
        .writer = .{ .context = null, .writeFn = writeStream },
        .state = .{ .context = null, .saveFn = saveState, .restoreFn = restoreState },
    };
}

pub fn inDir(comptime Ops: type, dir: *const std.Io.Dir) Ops {
    return .{
        .reader = .{ .context = @constCast(dir), .readFn = readAlloc },
        .writer = .{ .context = @constCast(dir), .writeFn = writeStream },
        .state = .{ .context = @constCast(dir), .saveFn = saveState, .restoreFn = restoreState },
    };
}
