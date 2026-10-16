//! Windows primitives for the shared native move peer driver (peer.zig):
//! pinned NT opens, a no-replace rename through the same pins, the process
//! identity the two replies of one exchange are matched by, and the immediate
//! watchdog exit.
const std = @import("std");
const w = std.os.windows;
const wire = @import("wire.zig");
const metadata = @import("../metadata.zig");
const layout = @import("../layout.zig");

extern "kernel32" fn GetProcessTimes(w.HANDLE, *w.FILETIME, *w.FILETIME, *w.FILETIME, *w.FILETIME) callconv(.winapi) w.BOOL;

pub fn leafPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return wire.windowsPath(allocator, path);
}

pub fn selfPid() u32 {
    return w.GetCurrentProcessId();
}

/// End the whole process from the watchdog without running anything that
/// could wait on a stalled thread.
pub fn terminate(code: u8) noreturn {
    _ = w.ntdll.NtTerminateProcess(w.GetCurrentProcess(), @fromBackingInt(@intCast(code)));
    std.process.exit(code);
}

/// The creation time of this process, reported beside its PID so the two
/// replies of one exchange can be matched. Never a signalling authority.
pub fn birth(io: std.Io) !u64 {
    _ = io;
    var created: w.FILETIME = undefined;
    var exited: w.FILETIME = undefined;
    var kernel: w.FILETIME = undefined;
    var user: w.FILETIME = undefined;
    if (!GetProcessTimes(w.GetCurrentProcess(), &created, &exited, &kernel, &user).toBool()) return error.ProcessIdentityUnavailable;
    const value = (@as(u64, created.dwHighDateTime) << 32) | created.dwLowDateTime;
    if (value == 0) return error.ProcessIdentityUnavailable;
    return value;
}

pub fn pinRoot(allocator: std.mem.Allocator, io: std.Io, root: wire.Root) !std.Io.Dir {
    if (root.path.len < 3 or !std.ascii.isAlphabetic(root.path[0]) or root.path[1] != ':' or root.path[2] != '\\') return error.UnsupportedRoot;
    if (!std.mem.eql(u8, root.marker, layout.root.marker_text) and !std.mem.eql(u8, root.marker, layout.root.kept_marker_text)) return error.Unmarked;
    const path = try std.fmt.allocPrint(allocator, "\\??\\{s}", .{root.path});
    defer allocator.free(path);
    var result = try pin(allocator, io, null, path, false);
    errdefer result.close(io);
    try metadata.expect(io, result, layout.root.marker, root.marker);
    return result;
}

pub fn pin(allocator: std.mem.Allocator, io: std.Io, root: ?std.Io.Dir, path: []const u8, deleting: bool) !std.Io.Dir {
    const utf16 = try std.unicode.wtf8ToWtf16LeAlloc(allocator, path);
    defer allocator.free(utf16);
    var unicode = w.UNICODE_STRING.init(utf16);
    const attributes: w.OBJECT.ATTRIBUTES = .{ .RootDirectory = if (root) |dir| dir.handle else null, .ObjectName = &unicode, .Attributes = .{ .DONT_REPARSE = true } };
    var handle: w.HANDLE = undefined;
    var iosb: w.IO_STATUS_BLOCK = undefined;
    const status = w.ntdll.NtCreateFile(&handle, .{ .SPECIFIC = .{ .FILE_DIRECTORY = .{ .LIST = true, .READ_ATTRIBUTES = true, .TRAVERSE = true } }, .STANDARD = .{ .RIGHTS = .{ .DELETE = deleting }, .SYNCHRONIZE = true } }, &attributes, &iosb, null, .{ .NORMAL = true }, .{ .READ = true, .WRITE = true }, .OPEN, .{ .DIRECTORY_FILE = true, .OPEN_REPARSE_POINT = true, .IO = .SYNCHRONOUS_NONALERT }, null, 0);
    if (status != .SUCCESS) return error.NativePinFailed;
    var result: std.Io.Dir = .{ .handle = handle };
    errdefer result.close(io);
    if ((try result.stat(io)).kind != .directory) return error.OutsideRoot;
    return result;
}

/// The rename the request commits: the pinned source entry into the target
/// root under `leaf`, refused rather than replacing whatever is already
/// there.
pub fn rename(allocator: std.mem.Allocator, source: std.Io.Dir, target: std.Io.Dir, leaf: []const u8) !wire.Status {
    const utf16 = try std.unicode.wtf8ToWtf16LeAlloc(allocator, leaf);
    defer allocator.free(utf16);
    var information: w.FILE.RENAME_INFORMATION = .init(.{ .Flags = .{}, .RootDirectory = target.handle, .FileName = utf16 });
    const bytes = information.toBuffer();
    var iosb: w.IO_STATUS_BLOCK = undefined;
    const status = w.ntdll.NtSetInformationFile(source.handle, &iosb, bytes.ptr, @intCast(bytes.len), .RenameEx);
    return switch (status) {
        .SUCCESS => .success,
        .OBJECT_NAME_COLLISION, .DIRECTORY_NOT_EMPTY => .collision,
        .NOT_SAME_DEVICE => .cross_device,
        else => .refused,
    };
}
